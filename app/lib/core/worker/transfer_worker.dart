/// Background isolate that owns everything heavy: TLS sockets, the PTP/1 session, the transfer engines and
/// SHA-256 hashing (audit P0-2). The UI isolate only receives events (QR, code to confirm, progress, batch
/// reports, errors) and answers questions (confirm pairing, approve manifest).
///
/// Platform-channel work the engine needs (closing an Android fd / iOS staged export, free space) is sent back
/// to the UI isolate as an `rpc` event, so no plugin has to run in a background isolate.
///
/// Messages are `[String type, Object? payload]`. Both isolates are in the same isolate group (Isolate.spawn),
/// so plain Dart objects (DeviceInfo, Capabilities, Manifest, TransferReport, PtpException) are sent as is.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/capabilities.dart';
import '../protocol/constants.dart';
import '../protocol/errors.dart';
import '../protocol/codec.dart';
import '../protocol/qr_payload.dart' show HotspotInfo;
import '../session/continuation.dart';
import '../session/identity.dart';
import '../session/session.dart';
import '../transfer/engine.dart';
import '../transfer/receiver_store.dart';

/// A file prepared by the UI isolate (Android `/proc/self/fd/N`, iOS staged export, picked document).
class WorkerSource extends TransferSource {
  WorkerSource(this.path, this.relPath, this.category, this.mime, this.mtimeMs, this.token, this._release);
  final String path;
  @override
  final String relPath;
  @override
  final String category;
  @override
  final String? mime;
  final int? mtimeMs;
  final String? token;
  final Future<void> Function(String token) _release;

  /// Size from the live file; mtime from the platform when known (stable across iOS re-exports → resume works).
  @override
  Future<SourceStat> stat() async {
    final s = await File(path).stat();
    if (s.type == FileSystemEntityType.notFound) throw PtpException(PtpErrorCode.fileChanged, 'source gone');
    return SourceStat(s.size, mtimeMs ?? s.modified.millisecondsSinceEpoch);
  }

  @override
  Future<RandomAccessFile> open() => File(path).open();

  @override
  Future<void> release() async {
    if (token != null) await _release(token!);
  }
}

/// Direct-to-destination sink backed by the platform plugin through the UI isolate (audit P1-7).
class _RpcMediaSink implements MediaSink {
  _RpcMediaSink(this._rpc, this._categories);
  final Future<Object?> Function(String op, Map<String, Object?> args) _rpc;
  final Set<String> _categories;

  @override
  bool supports(String category) => _categories.contains(category);

  @override
  Future<Map<String, String>> create(String category, String name, String? mime) async {
    final r = await _rpc('mediaCreate', {'category': category, 'name': name, 'mime': mime});
    if (r is! Map || r['uri'] is! String || r['path'] is! String) throw StateError('mediaCreate failed');
    return {'uri': r['uri'] as String, 'path': r['path'] as String};
  }

  @override
  Future<String> reopen(String uri) async {
    final r = await _rpc('mediaReopen', {'uri': uri});
    if (r is! String) throw StateError('mediaReopen failed');
    return r;
  }

  @override
  Future<String> publish(String uri) async {
    final r = await _rpc('mediaPublish', {'uri': uri});
    if (r is! String) throw PtpException(PtpErrorCode.internalError, 'publish failed');
    return r;
  }

  @override
  Future<void> delete(String uri) async => _rpc('mediaDelete', {'uri': uri});
}

/// Isolate entry point. First message sent back is this isolate's command SendPort.
void transferWorkerEntry(SendPort toMain) {
  final commands = ReceivePort();
  final w = _Worker(toMain, commands);
  toMain.send(commands.sendPort);
  commands.listen(w.handle);
}

class _Worker {
  _Worker(this._out, this._commands);
  final SendPort _out;
  final ReceivePort _commands;

  PtpHost? _host;
  PtpChannel? _ch;
  String? _joinUri;
  Uint8List? _resumeToken;
  late DeviceInfo _device;
  late Capabilities _caps;
  Completer<bool>? _confirm;
  Completer<bool>? _approve;
  CancelToken _cancel = CancelToken();
  final PauseGate _pause = PauseGate();
  ReceiverStore? _store;

  /// Audit P1-10: earlier unfinished transfers (with their keys) and the outcome of the continuation exchange.
  List<ContinuationRecord> _contCandidates = const [];
  ContinuationOutcome? _cont;
  final Map<int, Completer<Object?>> _rpcs = {};
  int _rpcSeq = 0;

  void _emit(String type, [Object? data]) => _out.send([type, data]);
  void _log(String event, Map<String, Object?> fields) => _emit('log', [event, fields]);

  Future<Object?> _rpc(String op, Map<String, Object?> args) {
    final id = _rpcSeq++;
    final c = Completer<Object?>();
    _rpcs[id] = c;
    _emit('rpc', {'id': id, 'op': op, 'args': args});
    return c.future;
  }

  void handle(dynamic raw) {
    final msg = raw as List<Object?>;
    final cmd = msg[0] as String;
    final a = msg.length > 1 ? msg[1] : null;
    switch (cmd) {
      case 'host':
        unawaited(_guard(() => _startHost(a as Map<String, Object?>)));
      case 'join':
        unawaited(_guard(() => _startJoin(a as Map<String, Object?>)));
      case 'confirm':
        _confirm?.complete(a == true);
        _confirm = null;
      case 'approve':
        _approve?.complete(a == true);
        _approve = null;
      case 'send':
        unawaited(_guard(() => _send(a as Map<String, Object?>)));
      case 'receive':
        unawaited(_guard(() => _receive(a as Map<String, Object?>)));
      case 'reconnect':
        unawaited(_guard(_reconnect));
      case 'dial':
        _dial(a as Map<String, Object?>);
      case 'pause':
        _pause.pause();
      case 'resume':
        _pause.resume();
      case 'cancel':
        _cancel.cancel();
        _confirm?.complete(false);
        _approve?.complete(false);
      case 'rpcReply':
        final m = a as Map<String, Object?>;
        _rpcs.remove(m['id'])?.complete(m['value']);
      case 'close':
        unawaited(_close());
    }
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } on PtpException catch (e) {
      _emit('error', e);
    } on TimeoutException {
      _emit('error', PtpException(PtpErrorCode.peerTimeout, 'timeout'));
    } catch (e) {
      _emit('error', PtpException(PtpErrorCode.internalError, e.runtimeType.toString()));
    }
  }

  Future<bool> _confirmCb(String sas, DeviceInfo peer) {
    _confirm = Completer<bool>();
    _emit('confirm', {'sas': sas, 'peer': peer});
    return _confirm!.future;
  }

  static List<ContinuationRecord> _parseCandidates(Object? raw) {
    final out = <ContinuationRecord>[];
    for (final m in (raw as List<Object?>?) ?? const []) {
      try {
        final j = (m as Map).cast<String, Object?>();
        out.add(ContinuationRecord.fromJson(j, unb64u(j['key'], length: 32)));
      } catch (_) {}
    }
    return out;
  }

  /// After a NEW pairing only (never after an in-session resume), and only if both apps implement it.
  Future<void> _negotiateContinuation() async {
    final ch = _ch!;
    if (ch.resumed) return;
    if (!ch.localCaps.features.contains(continuationFeature) || !ch.peerCaps.features.contains(continuationFeature)) {
      _cont = null;
      return;
    }
    _cont = await negotiateContinuation(ch, _contCandidates);
    _log('continuation', {'state': _cont!.continued ? 'continued' : 'new', 'count': _contCandidates.length});
  }

  void _paired() {
    final ch = _ch!;
    _resumeToken = ch.resumeToken;
    bool loopback;
    try {
      loopback = ch.socket.remoteAddress.isLoopback;
    } catch (_) {
      loopback = false;
    }
    final c = _cont;
    _emit('paired', {
      'peer': ch.peer,
      'plan': ch.plan.toList(),
      'resumed': ch.resumed,
      'loopback': loopback,
      if (!ch.resumed && c != null)
        'cont': {...c.record.toJson(), 'key': b64u(c.record.key), 'continued': c.continued},
    });
  }

  /// "Tự động" path switch (joiner only, it is the side that dials). Replaces the endpoints used by the next
  /// (re)connect; with `drop`, closes the live socket so the normal PTP/1 resume moves the session onto the new
  /// path: same session, certificate pinned again, resume proof, receiver continues from its checkpoints.
  void _dial(Map<String, Object?> a) {
    if (_host != null || _joinUri == null) return;
    _joinUri = a['uri'] as String;
    _log('path_dial', {'to': a['to'], 'state': a['drop'] == true ? 'drop' : 'next'});
    if (a['drop'] == true) _ch?.socket.destroy();
  }

  Future<void> _startHost(Map<String, Object?> a) async {
    _device = a['device'] as DeviceInfo;
    _caps = a['caps'] as Capabilities;
    final identity = await EphemeralIdentity.generate();
    final h = PtpHost(
        role: a['role'] as String,
        device: _device,
        confirm: _confirmCb,
        caps: _caps,
        identity: identity,
        loopbackOnly: a['loopbackOnly'] == true,
        flags: ((a['flags'] as List<Object?>?) ?? const []).cast<String>(),
        ap: a['ap'] == null ? null : HotspotInfo.parse(a['ap']),
        preferredHosts: ((a['apHosts'] as List<Object?>?) ?? const []).cast<String>());
    await h.start();
    _host = h;
    _contCandidates = _parseCandidates(a['cont']);
    _emit('qr', {'uri': h.qr.toUri(), 'expiresAt': h.expiresAt, 'endpoints': h.endpoints, 'port': h.port});
    _ch = await h.accept();
    await _negotiateContinuation();
    _paired();
  }

  Future<void> _startJoin(Map<String, Object?> a) async {
    _device = a['device'] as DeviceInfo;
    _caps = a['caps'] as Capabilities;
    _joinUri = a['uri'] as String;
    _contCandidates = _parseCandidates(a['cont']);
    _ch = await joinSession(_joinUri!, device: _device, confirm: _confirmCb, capsForRole: (_) => _caps);
    await _negotiateContinuation();
    _paired();
  }

  /// Emits progress at most every 100 ms per file (and always at a file's end) to keep the UI isolate idle.
  ProgressCallback _progress(String Function(int i) nameOf) {
    final sw = Stopwatch()..start();
    var lastIndex = -1;
    return (i, done, total, wire) {
      if (i != lastIndex || done == total || sw.elapsedMilliseconds >= 100) {
        lastIndex = i;
        sw.reset();
        _emit('progress', {'i': i, 'done': done, 'total': total, 'wire': wire, 'name': nameOf(i)});
      }
    };
  }

  Future<void> _send(Map<String, Object?> a) async {
    final items = (a['items'] as List<Object?>).cast<Map<String, Object?>>();
    final sources = [
      for (final it in items)
        WorkerSource(it['path'] as String, it['relPath'] as String, it['category'] as String, it['mime'] as String?,
            it['mtimeMs'] as int?, it['token'] as String?, (t) => _rpc('closeRead', {'token': t}))
    ];
    final rep = await runSender(_ch!, sources,
        transferId: a['transferId'] as String?,
        more: a['more'] == true,
        cancel: _cancel,
        pause: _pause,
        onProgress: _progress((i) => sources[i].relPath));
    _emit('batch', rep);
  }

  Future<void> _receive(Map<String, Object?> a) async {
    final cpDir = a['checkpoints'] as String;
    await Directory(cpDir).create(recursive: true);
    final mediaCats = ((a['mediaCategories'] as List<Object?>?) ?? const []).cast<String>().toSet();
    final cont = _cont;
    _store ??= ReceiverStore(
        a['inbox'] as String,
        // Checkpoints are MAC'd with the continuation key when there is one (audit P1-10).
        JsonCheckpointStore(cpDir, macKey: cont?.record.key, onRejected: (r) => _log('checkpoint_rejected', {'reason': r})),
        (path) async => (await _rpc('freeBytes', {'path': path})) as int,
        reserve: a['reserve'] as int? ?? storageReserve,
        media: mediaCats.isEmpty ? null : _RpcMediaSink(_rpc, mediaCats),
        importCopies: a['importCopies'] == true,
        verify: a['verify'] == 'full' ? VerifyMode.full : VerifyMode.size,
        onEvent: _log,
        // Partial data from an earlier session is reused only for transfers both phones agreed to continue.
        resumeAllowed: (tid) => cont != null && cont.continued && cont.record.transferIds.contains(tid));
    final store = _store!;
    while (true) {
      final rep = await runReceiver(_ch!, store,
          cancel: _cancel,
          onProgress: _progress((i) => store.manifest.files[i].path), approve: (m, needed) {
        _approve = Completer<bool>();
        _emit('approve', {'manifest': m, 'needed': needed});
        return _approve!.future;
      });
      if (rep.failed.isEmpty) {
        // Committed files have been moved out; drop the empty partial dir and its checkpoint.
        try {
          await store.deletePartials();
        } catch (_) {}
      }
      _emit('batch', rep);
      if (!rep.more) break;
    }
    _emit('receiveDone');
  }

  /// Host: wait for the peer to come back. Joiner: retry every 3 s within the resume window.
  Future<void> _reconnect() async {
    await _ch?.close();
    _ch = null;
    if (_host != null) {
      _host!.release();
      _ch = await _host!.accept().timeout(resumeWindow);
    } else {
      final deadline = DateTime.now().add(resumeWindow);
      while (_ch == null) {
        if (_cancel.isCancelled || DateTime.now().isAfter(deadline)) {
          throw PtpException(PtpErrorCode.peerTimeout, 'resume window elapsed');
        }
        try {
          _ch = await joinSession(_joinUri!,
              device: _device, confirm: _confirmCb, capsForRole: (_) => _caps, resumeToken: _resumeToken);
        } on PtpException catch (e) {
          _log('reconnect_attempt', {'code': e.code.wire});
          if (e.code != PtpErrorCode.peerTimeout && e.code != PtpErrorCode.sessionBusy) rethrow;
          // Busy = the host has not noticed the old socket closing yet (typical right after a path switch).
          await Future<void>.delayed(Duration(seconds: e.code == PtpErrorCode.sessionBusy ? 1 : 3));
        }
      }
    }
    _paired();
  }

  Future<void> _close() async {
    _cancel.cancel();
    try {
      await _ch?.close();
      await _host?.close();
    } catch (_) {}
    for (final c in _rpcs.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _cancel = CancelToken();
    _commands.close(); // nothing else keeps the isolate alive
  }
}

/// UI-isolate handle to the worker.
class TransferWorkerClient {
  TransferWorkerClient._(this._isolate, this._to, this._fromWorker, this.events);

  final Isolate _isolate;
  final SendPort _to;
  final ReceivePort _fromWorker;

  /// Events from the worker except `rpc` (answered here through [rpcHandler]).
  final Stream<(String, Object?)> events;

  static Future<TransferWorkerClient> spawn(
      Future<Object?> Function(String op, Map<String, Object?> args) rpcHandler) async {
    final from = ReceivePort();
    final iso = await Isolate.spawn(transferWorkerEntry, from.sendPort, debugName: 'ptp-transfer');
    final controller = StreamController<(String, Object?)>.broadcast();
    final first = Completer<SendPort>();
    late TransferWorkerClient client;
    from.listen((raw) async {
      if (raw is SendPort) {
        first.complete(raw);
        return;
      }
      final msg = raw as List<Object?>;
      final type = msg[0] as String;
      if (type == 'rpc') {
        final m = msg[1] as Map<String, Object?>;
        Object? value;
        try {
          value = await rpcHandler(m['op'] as String, (m['args'] as Map<String, Object?>?) ?? const {});
        } catch (_) {
          value = null;
        }
        client.send('rpcReply', {'id': m['id'], 'value': value});
        return;
      }
      controller.add((type, msg.length > 1 ? msg[1] : null));
    });
    final to = await first.future;
    client = TransferWorkerClient._(iso, to, from, controller.stream);
    return client;
  }

  void send(String cmd, [Object? data]) => _to.send([cmd, data]);

  /// Asks the worker to close sockets, then stops it.
  Future<void> dispose() async {
    send('close');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}
