/// Encoding and keyed-hash helpers for PTP/1 (proofs, SAS). Cross-checked by test/codec_test.dart
/// against contracts/test_vectors.json, which the Python reference peer generates.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'errors.dart';

final Random _rng = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

String b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64u(Object? text, {int? length}) {
  if (text is! String || text.length > 4096) {
    throw PtpException(PtpErrorCode.protocolError, 'bad base64 field');
  }
  final Uint8List out;
  try {
    out = base64Url.decode(base64Url.normalize(text));
  } on FormatException {
    throw PtpException(PtpErrorCode.protocolError, 'bad base64 field');
  }
  if (length != null && out.length != length) {
    throw PtpException(PtpErrorCode.protocolError, 'bad field length');
  }
  return out;
}

Uint8List hmacSha256(List<int> key, List<List<int>> parts) {
  final msg = BytesBuilder(copy: false);
  for (final p in parts) {
    msg.add(p);
  }
  return Uint8List.fromList(Hmac(sha256, key).convert(msg.takeBytes()).bytes);
}

final Uint8List _proofLabel = Uint8List.fromList(utf8.encode('ptp1/proof'));
final Uint8List _resumeLabel = Uint8List.fromList(utf8.encode('ptp1/resume'));
final Uint8List _sasLabel = Uint8List.fromList(utf8.encode('ptp1/sas'));

Uint8List pairingProof(List<int> sid, List<int> fp, List<int> nonceJ) => hmacSha256(sid, [_proofLabel, fp, nonceJ]);

Uint8List resumeProof(List<int> token, List<int> fp, List<int> nonceJ) =>
    hmacSha256(token, [_resumeLabel, fp, nonceJ]);

String sasCode(List<int> sid, List<int> fp, List<int> nonceJ, List<int> nonceH) {
  final h = hmacSha256(sid, [_sasLabel, fp, nonceJ, nonceH]);
  final v = ByteData.sublistView(h, 0, 4).getUint32(0, Endian.big) % 1000000;
  return v.toString().padLeft(6, '0');
}

/// Constant-time comparison for MACs and fingerprints.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Incremental SHA-256 that does not keep data in memory.
class StreamingSha256 {
  StreamingSha256() {
    _input = sha256.startChunkedConversion(_sink);
  }
  final _DigestSink _sink = _DigestSink();
  late final ByteConversionSink _input;

  void add(List<int> bytes) => _input.add(bytes);

  String hexDigest() {
    _input.close();
    return _sink.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
