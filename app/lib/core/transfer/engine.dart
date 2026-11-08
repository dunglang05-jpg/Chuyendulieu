/// Sender and receiver transfer engines (PROTOCOL_v1 §7). Bounded memory: at most [sendWindow] bytes
/// un-acknowledged, one chunk (≤ 4 MiB) in flight per read/write, hashes computed incrementally.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/codec.dart';
import '../protocol/constants.dart';
import '../protocol/errors.dart';
import '../protocol/framing.dart';
import '../protocol/manifest.dart';
import '../protocol/paths.dart';
import '../session/session.dart';
import 'receiver_store.dart';

class SourceStat {
  const SourceStat(this.size, this.mtimeMs);
  final int size;
  final int? mtimeMs;
  @override
  bool operator ==(Object other) => other is SourceStat && other.size == size && other.mtimeMs == mtimeMs;
  @override
  int get hashCode => Object.hash(size, mtimeMs);
}

/// Something the sender can stream. Platform adapters provide paths (Android: /proc/self/fd/N of a
/// content:// descriptor; iOS: exported Photos resource or a picked document copy).
abstract class TransferSource {
  String get relPath;
  String get category;
  String? get mime;
  Future<SourceStat> stat();
  Future<RandomAccessFile> open();
  Future<void> release() async {}
}

class FileSource extends TransferSource {
  FileSource(this.path, this.relPath, this.category, {this.mime, this.onRelease});
  final String path;
  @override
  final String relPath;
  @override
  final String category;
  @override
  final String? mime;
  final Future<void> Function()? onRelease;

  @override
  Future<SourceStat> stat() async {
    final s = await File(path).stat();
    if (s.type == FileSystemEntityType.notFound) throw PtpException(PtpErrorCode.fileChanged, 'source missing');
    return SourceStat(s.size, s.modified.millisecondsSinceEpoch);
  }

  @override
  Future<RandomAccessFile> open() => File(path).open();

  @override
  Future<void> release() async => onRelease?.call();
}

class CancelToken {
  bool _cancelled = false;
  final _c = Completer<void>();
  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _c.future;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _c.complete();
  }
}

class PauseGate {
  Completer<void>? _c;
  bool get isPaused => _c != null;
  void pause() => _c ??= Completer<void>();
  void resume() {
    _c?.complete();
    _c = null;
  }

  Future<void> wait() => _c?.future ?? Future.value();
}

typedef ProgressCallback = void Function(int index, int done, int total, int wireBytes);

class TransferReport {
  TransferReport(this.transferId);
  final String transferId;
  final List<int> ok = [];
  final Map<int, PtpErrorCode> failed = {};
  final List<int> skipped = [];
  final Map<int, String> committedPaths = {};
  int wireBytes = 0;
  Duration elapsed = Duration.zero;
  bool more = false;
  Manifest? manifest;

  double get mbPerSecond =>
      elapsed.inMicroseconds == 0 ? 0 : wireBytes / 1e6 / (elapsed.inMicroseconds / 1e6);
}

class _Signal {
  Completer<void> _c = Completer<void>();
  Future<void> get next => _c.future;
  void fire() {
    final old = _c;
    _c = Completer<void>();
    old.complete();
  }
}

/// Streams [sources] as one batch. Set [more] when another batch follows on the same channel.
Future<TransferReport> runSender(
  PtpChannel ch,
  List<TransferSource> sources, {
  String? transferId,
  int chunkSize = defaultChunk,
  bool more = false,
  ProgressCallback? onProgress,
  CancelToken? cancel,
  PauseGate? pause,
}) async {
  assert(ch.role == 'sender' && chunkSize >= 1 && chunkSize <= maxChunk);
  final entries = <FileEntry>[];
  final stats = <SourceStat>[];
  for (var i = 0; i < sources.length; i++) {
    final s = await sources[i].stat();
    stats.add(s);
    entries.add(FileEntry(
        index: i,
        path: validateRelativePath(sources[i].relPath),
        size: s.size,
        category: sources[i].category,
        mime: sources[i].mime,
        mtimeMs: s.mtimeMs));
  }
  final manifest = Manifest(transferId ?? b64u(randomBytes(16)), entries);
  final report = TransferReport(manifest.transferId)..manifest = manifest;
  final sw = Stopwatch()..start();
  await ch.writer.control(manifest.toJson());
  final resp = await ch.reader.expect('manifest_resp', maxLen: maxManifest + 1, timeout: confirmTimeout);
  if (resp['accept'] != true) throw PtpException(PtpErrorCode.fromWire(resp['error']), 'receiver rejected manifest');

  final offsets = <int, int>{};
  final already = <int>{};
  final files = resp['files'];
  if (files is! List) throw PtpException(PtpErrorCode.protocolError, 'bad manifest_resp');
  for (final item in files) {
    if (item is! Map) throw PtpException(PtpErrorCode.protocolError, 'bad manifest_resp entry');
    final i = item['i'];
    final off = item['offset'];
    if (i is! int || i < 0 || i >= entries.length || off is! int || off < 0 || off > entries[i].size) {
      throw PtpException(PtpErrorCode.protocolError, 'bad manifest_resp entry');
    }
    offsets[i] = off;
    if (item['done'] == true) already.add(i);
  }
  report.skipped.addAll([for (var i = 0; i < entries.length; i++) if (!offsets.containsKey(i)) i]);
  report.ok.addAll(already);

  final acked = Map<int, int>.of(offsets);
  final sent = Map<int, int>.of(offsets);
  final results = <int, String>{};
  final signal = _Signal();
  PtpException? failure;
  var peerReported = false;

  // Reads acks/results concurrently with sending.
  final readerDone = () async {
    try {
      while (true) {
        final f = await ch.reader.read(maxControl + 1);
        if (f is! ControlFrame) throw PtpException(PtpErrorCode.protocolError, 'receiver sent data');
        final m = f.msg;
        switch (m['t']) {
          case 'ack':
            final i = m['i'];
            final off = m['offset'];
            if (i is int && off is int && acked.containsKey(i) && off > acked[i]!) acked[i] = off;
          case 'file_result':
            final i = m['i'];
            if (i is int && acked.containsKey(i)) results[i] = '${m['status']}';
          case 'report':
            peerReported = true;
            signal.fire();
            return;
          case 'cancel':
            throw PtpException(PtpErrorCode.userCancelled, 'receiver cancelled');
        }
        signal.fire();
      }
    } on PtpException catch (e) {
      failure = e;
      signal.fire();
    }
  }();

  int inflight() => sent.values.fold(0, (a, b) => a + b) - acked.values.fold(0, (a, b) => a + b);

  Future<void> waitUntil(bool Function() pred) async {
    while (true) {
      if (failure != null) throw failure!;
      if (cancel?.isCancelled ?? false) {
        await ch.writer.control({'t': 'cancel', 'reason': 'user'});
        throw PtpException(PtpErrorCode.userCancelled, 'cancelled by user');
      }
      if (pred()) return;
      await Future.any([signal.next, if (cancel != null) cancel.whenCancelled]);
    }
  }

  var wire = 0;

  Future<void> sendFile(int i, int start, {bool corrupt = false}) async {
    final e = entries[i];
    final src = sources[i];
    if (await src.stat() != stats[i]) {
      await ch.writer.control({'t': 'file_skip', 'i': i, 'reason': 'FILE_CHANGED'});
      results[i] = 'FILE_CHANGED';
      return;
    }
    final hasher = StreamingSha256();
    final raf = await src.open();
    var pos = start;
    try {
      var remaining = start;
      while (remaining > 0) {
        final buf = await raf.read(remaining < 1 << 20 ? remaining : 1 << 20);
        if (buf.isEmpty) break;
        hasher.add(buf);
        remaining -= buf.length;
      }
      await raf.setPosition(start);
      while (pos < e.size) {
        await pause?.wait();
        final want = (e.size - pos) < chunkSize ? e.size - pos : chunkSize;
        await waitUntil(() => inflight() + want <= sendWindow);
        final Uint8List buf = await raf.read(want);
        if (buf.isEmpty) break; // truncated under us -> FILE_CHANGED below
        hasher.add(buf);
        await ch.writer.data(i, pos, buf);
        pos += buf.length;
        sent[i] = pos;
        wire += buf.length;
        onProgress?.call(i, pos, e.size, wire);
      }
    } finally {
      await raf.close();
    }
    if (pos != e.size || await src.stat() != stats[i]) {
      await ch.writer.control({'t': 'file_skip', 'i': i, 'reason': 'FILE_CHANGED'});
      results[i] = 'FILE_CHANGED';
      return;
    }
    await ch.writer.control({'t': 'file_end', 'i': i, 'size': e.size, 'sha256': hasher.hexDigest()});
  }

  final todo = [for (final i in offsets.keys.toList()..sort()) if (!already.contains(i)) i];
  try {
    for (final i in todo) {
      await sendFile(i, offsets[i]!);
      await sources[i].release();
    }
    await waitUntil(() => todo.every(results.containsKey));
    for (final i in todo.where((i) => results[i] == 'hash_mismatch').toList()) {
      results.remove(i); // one retry from scratch
      acked[i] = 0;
      sent[i] = 0;
      await sendFile(i, 0);
    }
    await waitUntil(() => todo.every(results.containsKey));
    await ch.writer.control({'t': 'done', 'more': more});
    await waitUntil(() => peerReported);
  } finally {
    for (final s in sources) {
      await s.release();
    }
  }
  await readerDone;
  for (final i in todo) {
    final r = results[i];
    if (r == 'ok') {
      report.ok.add(i);
    } else {
      report.failed[i] = r == 'hash_mismatch' ? PtpErrorCode.hashMismatch : PtpErrorCode.fromWire(r);
    }
  }
  report.ok.sort();
  report.wireBytes = wire;
  report.elapsed = sw.elapsed;
  return report;
}

/// Receives one batch into [store]. `report.more` tells the caller to run again for the next batch.
Future<TransferReport> runReceiver(
  PtpChannel ch,
  ReceiverStore store, {
  ProgressCallback? onProgress,
  CancelToken? cancel,
  Future<bool> Function(Manifest m, int neededBytes)? approve,
}) async {
  assert(ch.role == 'receiver');
  final msg = await ch.reader.expect('manifest', maxLen: maxManifest + 1, timeout: const Duration(hours: 1));
  final manifest = Manifest.fromJson(msg);
  final plan = ch.plan;
  final accepted = [for (final e in manifest.files) if (plan.contains(e.category)) e.index];
  final offsets = await store.prepare(manifest, accepted);
  final needed = offsets.entries.fold<int>(0, (a, e) => a + manifest.files[e.key].size - e.value);
  try {
    await store.checkCapacity(needed);
  } on PtpException {
    final free = await store.freeSpace(store.root);
    await ch.writer.control({
      't': 'manifest_resp',
      'accept': false,
      'error': PtpErrorCode.storageInsufficient.wire,
      'needed': needed,
      'available': free - store.reserve < 0 ? 0 : free - store.reserve,
    });
    rethrow;
  }
  if (approve != null && !await approve(manifest, needed)) {
    await ch.writer.control({'t': 'manifest_resp', 'accept': false, 'error': PtpErrorCode.userCancelled.wire});
    throw PtpException(PtpErrorCode.userCancelled, 'receiver declined');
  }
  await ch.writer.control({
    't': 'manifest_resp',
    'accept': true,
    'transferId': manifest.transferId,
    'files': [
      for (final i in offsets.keys.toList()..sort()) {'i': i, 'offset': offsets[i], 'done': store.isDone(i)}
    ],
  });
  final report = TransferReport(manifest.transferId)..manifest = manifest;
  report.skipped.addAll([for (final e in manifest.files) if (!offsets.containsKey(e.index)) e.index]);
  final expected = Map<int, int>.of(offsets);
  for (final i in offsets.keys) {
    if (store.isDone(i)) {
      report.ok.add(i);
      final fp = store.finalPath(i);
      if (fp != null) report.committedPaths[i] = fp;
    }
  }
  OpenPart? cur;
  var sinceAck = 0;
  final sw = Stopwatch()..start();

  Future<OpenPart> ensureOpen(int i) async {
    if (cur?.index == i) return cur!;
    await cur?.raf.close();
    cur = await store.openPart(i, expected[i]!);
    sinceAck = 0;
    return cur!;
  }

  try {
    while (true) {
      if (cancel?.isCancelled ?? false) {
        await ch.writer.control({'t': 'cancel', 'reason': 'user'});
        throw PtpException(PtpErrorCode.userCancelled, 'cancelled by user');
      }
      final Frame f;
      try {
        f = await ch.reader.read(maxDataFrame).timeout(idleTimeout);
      } on TimeoutException {
        throw PtpException(PtpErrorCode.peerTimeout, 'sender idle');
      }
      switch (f) {
        case DataFrame(:final index, :final offset, :final payload):
          if (!expected.containsKey(index) || store.isDone(index)) {
            throw PtpException(PtpErrorCode.protocolError, 'data for unaccepted file');
          }
          if (offset != expected[index]) {
            throw PtpException(PtpErrorCode.resumeStateInvalid, 'file $index: offset $offset != ${expected[index]}');
          }
          if (offset + payload.length > manifest.files[index].size) {
            throw PtpException(PtpErrorCode.manifestInvalid, 'data beyond declared size');
          }
          final part = await ensureOpen(index);
          await part.raf.writeFrom(payload);
          part.hasher.add(payload);
          expected[index] = expected[index]! + payload.length;
          report.wireBytes += payload.length;
          sinceAck += payload.length;
          if (sinceAck >= ackInterval) {
            await store.checkpoint(part, expected[index]!);
            await ch.writer.control({'t': 'ack', 'i': index, 'offset': expected[index]});
            sinceAck = 0;
          }
          onProgress?.call(index, expected[index]!, manifest.files[index].size, report.wireBytes);
        case ControlFrame(:final msg):
          switch (msg['t']) {
            case 'file_end':
              final i = msg['i'];
              if (i is! int || !expected.containsKey(i) || store.isDone(i)) {
                throw PtpException(PtpErrorCode.protocolError, 'file_end for unaccepted file');
              }
              final part = await ensureOpen(i);
              final digest = msg['sha256'];
              final sizeOk = expected[i] == manifest.files[i].size && msg['size'] == manifest.files[i].size;
              String status;
              if (sizeOk && digest is String && constantTimeEquals(part.hasher.hexDigest().codeUnits, digest.toLowerCase().codeUnits)) {
                final dest = await store.commit(part);
                report.committedPaths[i] = dest;
                if (!report.ok.contains(i)) report.ok.add(i);
                report.failed.remove(i);
                status = 'ok';
              } else {
                await store.discard(i, part);
                expected[i] = 0;
                report.failed[i] = PtpErrorCode.hashMismatch;
                status = 'hash_mismatch';
              }
              cur = null;
              await ch.writer.control({'t': 'ack', 'i': i, 'offset': expected[i]});
              await ch.writer.control({'t': 'file_result', 'i': i, 'status': status});
            case 'file_skip':
              final i = msg['i'];
              if (i is int && expected.containsKey(i)) {
                report.failed[i] = PtpErrorCode.fileChanged;
                await ch.writer.control({'t': 'file_result', 'i': i, 'status': 'FILE_CHANGED'});
              }
            case 'done':
              report.more = msg['more'] == true;
              await ch.writer.control(
                  {'t': 'report', 'ok': report.ok.length, 'failed': report.failed.length, 'skipped': report.skipped.length});
              report.ok.sort();
              report.elapsed = sw.elapsed;
              return report;
            case 'cancel':
              throw PtpException(PtpErrorCode.userCancelled, 'sender cancelled');
            default:
              throw PtpException(PtpErrorCode.protocolError, 'unexpected ${msg['t']}');
          }
      }
    }
  } finally {
    await cur?.raf.close();
  }
}
