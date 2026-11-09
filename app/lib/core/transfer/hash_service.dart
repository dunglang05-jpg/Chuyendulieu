/// SHA-256 off the transfer isolate.
///
/// Device test 2026-11-09 (Wi-Fi Direct 5 GHz, 3.96 GB): the sender spent 82 s and the receiver 90 s hashing,
/// inline, in the same isolate that feeds the TLS socket. While Dart code hashes, that isolate cannot pump the
/// socket. [HashService] runs the hashing in its own long-lived isolate. Chunks are copied over once and
/// processed in order, and the transfer loop only waits for the final digest of each file.
///
/// Small files are hashed inline, because a round trip per file would cost more than the hashing itself.
/// The verification itself is unchanged: same SHA-256, same comparison, same place in the protocol.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../protocol/codec.dart';

/// Incremental SHA-256 whose digest may be ready later.
abstract class Sha256Sink {
  void add(Uint8List bytes);
  Future<String> digest();
}

/// Same-isolate hashing (tests, small files, no service).
class InlineSha256 implements Sha256Sink {
  final _h = StreamingSha256();
  @override
  void add(Uint8List bytes) => _h.add(bytes);
  @override
  Future<String> digest() async => _h.hexDigest();
}

class HashService {
  HashService._(this._isolate, this._to, this._from);

  final Isolate _isolate;
  final SendPort _to;
  final ReceivePort _from;
  final Map<int, Completer<String>> _pending = {};
  var _next = 0;
  var _closed = false;

  /// Files at least this large are hashed in the service isolate.
  static const int offThreadMin = 1 << 20;

  static Future<HashService> spawn() async {
    final from = ReceivePort();
    final iso = await Isolate.spawn(_main, from.sendPort, debugName: 'ptp-hash');
    final first = Completer<SendPort>();
    late final HashService svc;
    from.listen((m) {
      if (!first.isCompleted) {
        first.complete(m as SendPort);
        return;
      }
      final l = m as List<Object?>;
      svc._pending.remove(l[0] as int)?.complete(l[1] as String);
    });
    svc = HashService._(iso, await first.future, from);
    return svc;
  }

  /// A new hash for one file. [sizeHint] = bytes that will be added (file size).
  Sha256Sink open(int sizeHint) => (_closed || sizeHint < offThreadMin) ? InlineSha256() : _RemoteSha256(this, _next++);

  void close() {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('hash service closed'));
    }
    _pending.clear();
    _from.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  static void _main(SendPort reply) {
    final rp = ReceivePort();
    reply.send(rp.sendPort);
    final open = <int, StreamingSha256>{};
    rp.listen((m) {
      final l = m as List<Object?>;
      final id = l[1] as int;
      switch (l[0]) {
        case 'a':
          (open[id] ??= StreamingSha256()).add((l[2] as TransferableTypedData).materialize().asUint8List());
        case 'd':
          reply.send([id, (open.remove(id) ?? StreamingSha256()).hexDigest()]);
      }
    });
  }
}

class _RemoteSha256 implements Sha256Sink {
  _RemoteSha256(this._svc, this._id);
  final HashService _svc;
  final int _id;

  @override
  void add(Uint8List bytes) {
    if (_svc._closed) throw StateError('hash service closed');
    // One copy into a transferable buffer; messages on one port are processed in order.
    _svc._to.send(['a', _id, TransferableTypedData.fromList([bytes])]);
  }

  @override
  Future<String> digest() {
    if (_svc._closed) return Future.error(StateError('hash service closed'));
    final c = Completer<String>();
    _svc._pending[_id] = c;
    _svc._to.send(['d', _id]);
    return c.future;
  }
}
