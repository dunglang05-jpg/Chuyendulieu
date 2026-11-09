/// Receiver durable store: partial files, fsync'd checkpoints, atomic commit, capacity check.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../protocol/codec.dart';
import '../protocol/errors.dart';
import '../protocol/manifest.dart';
import '../protocol/paths.dart';
import '../session/continuation.dart' show macJson, checkMacJson;

/// Persistence for per-file resume state. JSON implementation below; the app uses SQLite (data/db.dart).
abstract class CheckpointStore {
  Future<Map<String, dynamic>> load(String transferId);
  Future<void> save(String transferId, Map<String, dynamic> state);
  Future<void> delete(String transferId);
}

class JsonCheckpointStore implements CheckpointStore {
  /// With [macKey] (the continuation key, audit P1-10) every checkpoint carries an HMAC and a checkpoint whose MAC
  /// does not verify — edited, truncated, written by someone else — is treated as absent: the file restarts.
  JsonCheckpointStore(this.dir, {this.macKey, this.onRejected});
  final String dir;
  final List<int>? macKey;
  final void Function(String reason)? onRejected;

  File _f(String tid) => File(p.join(dir, '$tid.state.json'));

  @override
  Future<Map<String, dynamic>> load(String tid) async {
    final f = _f(tid);
    if (!await f.exists()) return {};
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is! Map<String, dynamic>) throw const FormatException('not an object');
      final key = macKey;
      if (key == null) return j;
      final body = j['body'];
      if (body is! Map<String, dynamic> || !checkMacJson(key, body, j['mac'])) {
        onRejected?.call('mac');
        return {};
      }
      return body;
    } catch (_) {
      onRejected?.call('corrupt');
      return {};
    }
  }

  @override
  Future<void> save(String tid, Map<String, dynamic> state) async {
    final tmp = File('${_f(tid).path}.tmp');
    final raf = await tmp.open(mode: FileMode.write);
    final key = macKey;
    final doc = key == null ? state : {'body': state, 'mac': macJson(key, state)};
    await raf.writeFrom(utf8.encode(jsonEncode(doc)));
    await raf.flush(); // fsync
    await raf.close();
    await tmp.rename(_f(tid).path); // atomic replace
  }

  @override
  Future<void> delete(String tid) async {
    if (await _f(tid).exists()) await _f(tid).delete();
  }
}

/// Free bytes on the volume holding [path]; provided by the platform adapter (statvfs / NSURL resource values).
typedef FreeSpaceProbe = Future<int> Function(String path);

/// Prefix of a committed location that is already in its final shared place (no import copy needed).
const publishedPrefix = 'published:';

/// A destination the receiver writes into directly, so each byte is written once (audit P1-7).
/// Android: a MediaStore item with IS_PENDING=1 (hidden until published; MediaStore deletes abandoned pending items
/// on its own after about a week). The returned path must be openable read+write by this process.
abstract class MediaSink {
  bool supports(String category);

  /// New pending item; returns {'uri': …, 'path': …}.
  Future<Map<String, String>> create(String category, String name, String? mime);

  /// Path for an existing pending item (after a reconnect or a restart). Throws if the item is gone.
  Future<String> reopen(String uri);

  /// Makes the item visible in the gallery / Downloads; returns a user-readable location.
  Future<String> publish(String uri);

  Future<void> delete(String uri);
}

/// ENOSPC / EDQUOT while writing → STORAGE_INSUFFICIENT (resumable after the user frees space), not INTERNAL_ERROR.
PtpException mapWriteError(FileSystemException e) {
  final code = e.osError?.errorCode;
  if (code == 28 || code == 122 || code == 69) {
    // 28 ENOSPC (Linux/Android/iOS), 122 EDQUOT (Linux), 69 EDQUOT (Darwin)
    return PtpException(PtpErrorCode.storageInsufficient, 'disk full while writing');
  }
  return PtpException(PtpErrorCode.internalError, 'write failed (${code ?? '?'})');
}

class OpenPart {
  OpenPart(this.raf, this.hasher, this.index);
  final RandomAccessFile raf;
  final StreamingSha256 hasher;
  final int index;
}

class ReceiverStore {
  ReceiverStore(this.root, this.checkpoints, this.freeSpace,
      {this.reserve = 256 * 1024 * 1024, this.media, this.importCopies = false, this.onEvent, this.resumeAllowed});

  final String root; // app-private inbox; files the media sink cannot take are imported from here after commit
  final CheckpointStore checkpoints;
  final FreeSpaceProbe freeSpace;
  final int reserve;

  /// Direct-to-destination writer (Android MediaStore). Null: everything goes through the inbox.
  final MediaSink? media;

  /// True when importing an inbox file COPIES it (Android MediaStore insert from the inbox); false when it is moved
  /// (iOS Photos shouldMoveFile, Files) or not imported at all. Used for the capacity check.
  final bool importCopies;

  /// Audit P1-10: may partial data of this transfer id from an EARLIER session be reused? Null = always (tests,
  /// legacy). Ids already seen by this store (reconnects within the session) are always allowed.
  final bool Function(String transferId)? resumeAllowed;
  final Set<String> _sessionTids = {};

  /// Non-sensitive events for the diagnostic log (e.g. media sink fallback).
  final void Function(String event, Map<String, Object?> fields)? onEvent;
  late Manifest manifest;
  late Map<String, dynamic> _files; // "i" -> {ident, durable, done, final, uri?, path?}

  String get _partialDir => p.join(root, '.ptp-partial', manifest.transferId);
  String _inboxPart(int i) => p.join(_partialDir, '$i.part');

  /// Where file [i]'s bytes are being written: a pending media item or the inbox partial.
  String partPath(int i) => (_files['$i']?['path'] as String?) ?? _inboxPart(i);
  bool _onMedia(int i) => _files['$i']?['uri'] is String;

  Future<Map<int, int>> prepare(Manifest m, List<int> accepted) async {
    manifest = m;
    await Directory(_partialDir).create(recursive: true);
    final allowed = _sessionTids.contains(m.transferId) || (resumeAllowed?.call(m.transferId) ?? true);
    _sessionTids.add(m.transferId);
    final old = allowed ? (await checkpoints.load(m.transferId))['files'] : null;
    final prev = old is Map<String, dynamic> ? old : <String, dynamic>{};
    if (!allowed) {
      // Not agreed by both phones: never build on bytes left by an earlier, unverified session.
      onEvent?.call('resume_refused', {'state': 'not_agreed'});
      final d = Directory(_partialDir);
      if (await d.exists()) await d.delete(recursive: true);
      await Directory(_partialDir).create(recursive: true);
    }
    _files = {};
    final offsets = <int, int>{};
    for (final i in accepted) {
      final e = m.files[i];
      final ident = jsonEncode(e.ident);
      final pr = prev['$i'];
      final same = pr is Map && pr['ident'] == ident;
      if (same && pr['done'] == true) {
        _files['$i'] = {'ident': ident, 'durable': e.size, 'done': true, 'final': pr['final']};
        offsets[i] = e.size;
        continue;
      }
      var durable = same && pr['durable'] is int ? pr['durable'] as int : 0;
      final rec = <String, dynamic>{'ident': ident, 'durable': 0, 'done': false, 'final': null};
      // A pending media item from an earlier connection of this transfer: reuse it if it is still there.
      final oldUri = same && pr['uri'] is String ? pr['uri'] as String : null;
      if (oldUri != null && media != null) {
        try {
          rec['path'] = await media!.reopen(oldUri);
          rec['uri'] = oldUri;
        } catch (_) {
          durable = 0; // item gone (expired / deleted by the user): start this file again
        }
      } else if (oldUri != null) {
        durable = 0;
      }
      _files['$i'] = rec;
      final target = File(partPath(i));
      if (durable > 0 && (!await _exists(target) || await target.length() < durable || durable > e.size)) durable = 0;
      if (rec['uri'] != null || await target.exists()) {
        try {
          final raf = await target.open(mode: FileMode.append);
          await raf.truncate(durable); // drop bytes written after the last fsync'd checkpoint
          await raf.close();
        } on FileSystemException {
          if (rec['uri'] == null) rethrow;
          // Pending item reopened but not writable from here: forget it, the file restarts in the inbox.
          onEvent?.call('media_sink_fallback', {'category': e.category, 'state': 'reopen'});
          final uri = rec.remove('uri') as String;
          rec.remove('path');
          try {
            await media!.delete(uri);
          } catch (_) {}
          durable = 0;
        }
      }
      rec['durable'] = durable;
      offsets[i] = durable;
    }
    await _save();
    return offsets;
  }

  Future<void> _save() => checkpoints.save(manifest.transferId, {'transferId': manifest.transferId, 'files': _files});

  static Future<bool> _exists(File f) async {
    try {
      return await f.exists();
    } catch (_) {
      return false;
    }
  }

  bool isDone(int i) => _files['$i']?['done'] == true;

  /// Bytes the receiver needs free for this batch: what is left to receive, plus, when an import copies the file
  /// out of the inbox, the largest such file (imports run one at a time and delete the inbox copy afterwards).
  int requiredBytes(Map<int, int> offsets) {
    var left = 0;
    var copyPeak = 0;
    for (final e in offsets.entries) {
      if (isDone(e.key)) continue;
      final f = manifest.files[e.key];
      left += f.size - e.value;
      final direct = media?.supports(f.category) ?? false;
      if (importCopies && !direct && f.category != 'contacts' && f.size > copyPeak) copyPeak = f.size;
    }
    return left + copyPeak;
  }
  String? finalPath(int i) => _files['$i']?['final'] as String?;

  Future<void> checkCapacity(int needed) async {
    final free = await freeSpace(root);
    if (free - reserve < needed) {
      throw PtpException(PtpErrorCode.storageInsufficient, 'need $needed bytes, ${free - reserve} available');
    }
  }

  Future<OpenPart> openPart(int i, int offset) async {
    final e = manifest.files[i];
    if (!_onMedia(i) && offset == 0 && (media?.supports(e.category) ?? false)) {
      try {
        final item = await media!.create(e.category, p.basename(e.path), e.mime);
        _files['$i']
          ..['uri'] = item['uri']
          ..['path'] = item['path'];
        await _save();
      } catch (_) {
        onEvent?.call('media_sink_fallback', {'category': e.category, 'state': 'create'});
      }
    }
    RandomAccessFile raf;
    try {
      raf = await File(partPath(i)).open(mode: FileMode.append); // creates if missing; read+write
    } on FileSystemException catch (err) {
      if (!_onMedia(i) || offset != 0) throw mapWriteError(err);
      // The pending item exists but this process cannot open its path: drop it, use the inbox for this file.
      onEvent?.call('media_sink_fallback', {'category': e.category, 'state': 'open'});
      final uri = _files['$i']['uri'] as String;
      _files['$i']
        ..remove('uri')
        ..remove('path');
      await _save();
      try {
        await media!.delete(uri);
      } catch (_) {}
      await Directory(_partialDir).create(recursive: true);
      raf = await File(partPath(i)).open(mode: FileMode.append);
    }
    await raf.truncate(offset);
    final hasher = StreamingSha256();
    await raf.setPosition(0);
    var remaining = offset;
    while (remaining > 0) {
      final buf = await raf.read(remaining < 1 << 20 ? remaining : 1 << 20);
      if (buf.isEmpty) {
        await raf.close();
        throw PtpException(PtpErrorCode.resumeStateInvalid, 'partial shorter than checkpoint');
      }
      hasher.add(buf);
      remaining -= buf.length;
    }
    await raf.setPosition(offset);
    return OpenPart(raf, hasher, i);
  }

  Future<void> write(OpenPart part, List<int> bytes) async {
    try {
      await part.raf.writeFrom(bytes);
    } on FileSystemException catch (e) {
      throw mapWriteError(e);
    }
  }

  Future<void> checkpoint(OpenPart part, int offset) async {
    try {
      await part.raf.flush(); // fsync
    } on FileSystemException catch (e) {
      throw mapWriteError(e);
    }
    _files['${part.index}']['durable'] = offset;
    await _save();
  }

  /// fsync, then either publish the pending media item in place (no copy) or atomically rename the inbox partial
  /// into `<root>/<category>/<path>` (unique name, never overwrite).
  Future<String> commit(OpenPart part) async {
    final e = manifest.files[part.index];
    try {
      await part.raf.flush();
    } on FileSystemException catch (err) {
      throw mapWriteError(err);
    }
    await part.raf.close();
    if (_onMedia(part.index)) {
      final location = await media!.publish(_files['${part.index}']['uri'] as String);
      final dest = '$publishedPrefix$location';
      _files['${part.index}']
        ..['done'] = true
        ..['durable'] = e.size
        ..['final'] = dest;
      await _save();
      return dest;
    }
    var dest = resolveInside(root, '${e.category}/${e.path}');
    await Directory(p.dirname(dest)).create(recursive: true);
    dest = uniqueDestination(dest);
    await File(partPath(part.index)).rename(dest);
    _files['${part.index}']
      ..['done'] = true
      ..['durable'] = e.size
      ..['final'] = dest;
    await _save();
    return dest;
  }

  Future<void> discard(int i, [OpenPart? part]) async {
    await part?.raf.close();
    if (_onMedia(i)) {
      final uri = _files['$i']['uri'] as String;
      _files['$i']
        ..remove('uri')
        ..remove('path');
      try {
        await media!.delete(uri);
      } catch (_) {}
    } else {
      final f = File(partPath(i));
      if (await f.exists()) await f.delete();
    }
    _files['$i']['durable'] = 0;
    await _save();
  }

  /// User action "Xóa dữ liệu tạm": remove partial data of this transfer, including pending media items.
  Future<void> deletePartials() async {
    for (final i in _files.keys) {
      final r = _files[i];
      if (r is Map && r['done'] != true && r['uri'] is String) {
        try {
          await media?.delete(r['uri'] as String);
        } catch (_) {}
      }
    }
    final d = Directory(_partialDir);
    if (await d.exists()) await d.delete(recursive: true);
    await checkpoints.delete(manifest.transferId);
  }
}
