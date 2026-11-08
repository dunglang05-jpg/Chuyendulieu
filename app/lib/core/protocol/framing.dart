/// Length-prefixed framing over a byte stream (PROTOCOL_v1 §4).
///
/// [FrameReader] is pull-based: it only asks the socket for more bytes when a frame is being read, so a
/// slow consumer applies TCP backpressure instead of buffering unboundedly.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'constants.dart';
import 'errors.dart';

sealed class Frame {}

class ControlFrame extends Frame {
  ControlFrame(this.msg);
  final Map<String, dynamic> msg;
  String get type => msg['t'] as String;
}

class DataFrame extends Frame {
  DataFrame(this.index, this.offset, this.payload);
  final int index;
  final int offset;
  final Uint8List payload;
}

class FrameReader {
  FrameReader(Stream<Uint8List> source) : _it = StreamIterator(source);

  final StreamIterator<Uint8List> _it;
  final Queue<Uint8List> _chunks = Queue();
  int _buffered = 0;

  Future<Uint8List> _readExactly(int n) async {
    while (_buffered < n) {
      final bool more;
      try {
        more = await _it.moveNext();
      } on SocketException catch (e) {
        throw PtpException(PtpErrorCode.networkInterrupted, e.message);
      } on TlsException catch (e) {
        throw PtpException(PtpErrorCode.networkInterrupted, e.message);
      } on StateError catch (e) {
        throw PtpException(PtpErrorCode.networkInterrupted, e.message);
      }
      if (!more) throw PtpException(PtpErrorCode.networkInterrupted, 'peer closed connection');
      final c = _it.current;
      if (c.isNotEmpty) {
        _chunks.add(c);
        _buffered += c.length;
      }
    }
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final head = _chunks.removeFirst();
      final take = (n - filled) < head.length ? n - filled : head.length;
      out.setRange(filled, filled + take, head);
      filled += take;
      if (take < head.length) _chunks.addFirst(Uint8List.sublistView(head, take));
    }
    _buffered -= n;
    return out;
  }

  /// Reads one frame. Error frames from the peer are thrown as [PtpException].
  Future<Frame> read(int maxLen) async {
    final hdr = await _readExactly(4);
    final length = ByteData.sublistView(hdr).getUint32(0, Endian.big);
    if (length < 1 || length > maxLen) {
      throw PtpException(PtpErrorCode.protocolError, 'frame length $length out of bounds');
    }
    final body = await _readExactly(length);
    final type = body[0];
    if (type == frameControl) {
      if (length - 1 > maxManifest) throw PtpException(PtpErrorCode.protocolError, 'control frame too large');
      final Object? msg;
      try {
        msg = jsonDecode(utf8.decode(Uint8List.sublistView(body, 1)));
      } on FormatException {
        throw PtpException(PtpErrorCode.protocolError, 'control frame not JSON');
      }
      if (msg is! Map<String, dynamic> || msg['t'] is! String) {
        throw PtpException(PtpErrorCode.protocolError, 'control frame missing type');
      }
      if (!largeControl.contains(msg['t']) && length - 1 > maxControl) {
        throw PtpException(PtpErrorCode.protocolError, 'control frame too large');
      }
      if (msg['t'] == 'error') {
        final m = msg['message'];
        throw PtpException(PtpErrorCode.fromWire(msg['code']), m is String ? m : '');
      }
      return ControlFrame(msg);
    }
    if (type == frameData) {
      if (length - 1 <= dataHeaderSize || length - 1 - dataHeaderSize > maxChunk) {
        throw PtpException(PtpErrorCode.protocolError, 'bad data frame');
      }
      final bd = ByteData.sublistView(body);
      return DataFrame(bd.getUint32(1, Endian.big), bd.getUint64(5, Endian.big),
          Uint8List.sublistView(body, 1 + dataHeaderSize));
    }
    throw PtpException(PtpErrorCode.protocolError, 'unknown frame type $type');
  }

  /// Reads a control frame of type [t]; a peer `cancel` becomes [PtpErrorCode.userCancelled].
  Future<Map<String, dynamic>> expect(String t, {int maxLen = maxControl + 1, Duration timeout = handshakeTimeout}) async {
    final Frame f;
    try {
      f = await read(maxLen).timeout(timeout);
    } on TimeoutException {
      throw PtpException(PtpErrorCode.peerTimeout, 'waiting for $t');
    }
    if (f is! ControlFrame) throw PtpException(PtpErrorCode.protocolError, 'expected $t, got data');
    if (f.type == 'cancel') throw PtpException(PtpErrorCode.userCancelled, 'peer cancelled');
    if (f.type != t) throw PtpException(PtpErrorCode.protocolError, 'expected $t, got ${f.type}');
    return f.msg;
  }

  Future<void> cancel() => _it.cancel();
}

/// Serialises writes from several async callers onto one socket.
class FrameWriter {
  FrameWriter(this._sink);
  final IOSink _sink;
  Future<void> _tail = Future.value();

  Future<void> _enqueue(List<Uint8List> parts) {
    final next = _tail.then((_) async {
      // Any failure to hand bytes to the socket (reset, closed sink, TLS error) is a network loss,
      // so the controller's resume path always triggers.
      try {
        for (final p in parts) {
          _sink.add(p);
        }
        await _sink.flush();
      } on PtpException {
        rethrow;
      } catch (e) {
        throw PtpException(PtpErrorCode.networkInterrupted, e.runtimeType.toString());
      }
    });
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> control(Map<String, Object?> msg) {
    final body = utf8.encode(jsonEncode(msg));
    final hdr = ByteData(5)
      ..setUint32(0, body.length + 1, Endian.big)
      ..setUint8(4, frameControl);
    return _enqueue([hdr.buffer.asUint8List(), Uint8List.fromList(body)]);
  }

  Future<void> data(int index, int offset, Uint8List payload) {
    final hdr = ByteData(5 + dataHeaderSize)
      ..setUint32(0, 1 + dataHeaderSize + payload.length, Endian.big)
      ..setUint8(4, frameData)
      ..setUint32(5, index, Endian.big)
      ..setUint64(9, offset, Endian.big);
    return _enqueue([hdr.buffer.asUint8List(), payload]);
  }

  Future<void> error(PtpErrorCode code, String message) async {
    try {
      await control({'t': 'error', 'code': code.wire, 'message': message.length > 200 ? message.substring(0, 200) : message})
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
