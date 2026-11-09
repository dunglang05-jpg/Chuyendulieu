/// QR/session payload (PROTOCOL_v1 §2). Contains no PII, no credentials, no file names.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'codec.dart';
import 'constants.dart';
import 'errors.dart';

class Endpoint {
  const Endpoint(this.address, this.port);
  final InternetAddress address;
  final int port;

  static Endpoint parse(Object? text) {
    if (text is! String || text.length > 64) {
      throw PtpException(PtpErrorCode.protocolError, 'bad endpoint');
    }
    String host;
    String port;
    if (text.startsWith('[')) {
      final close = text.indexOf(']:');
      if (close < 0) throw PtpException(PtpErrorCode.protocolError, 'bad endpoint');
      host = text.substring(1, close);
      port = text.substring(close + 2);
    } else {
      final idx = text.lastIndexOf(':');
      if (idx < 0) throw PtpException(PtpErrorCode.protocolError, 'bad endpoint');
      host = text.substring(0, idx);
      port = text.substring(idx + 1);
    }
    final addr = InternetAddress.tryParse(host);
    final p = int.tryParse(port);
    if (addr == null || p == null || p < 1 || p > 65535) {
      throw PtpException(PtpErrorCode.protocolError, 'bad endpoint');
    }
    return Endpoint(addr, p);
  }

  @override
  String toString() =>
      address.type == InternetAddressType.IPv6 ? '[${address.address}]:$port' : '${address.address}:$port';
}

/// QR flag: the host chose "Tự động" (Wi-Fi, may move to a USB-C cable when both phones are Android).
const usbAutoFlag = 'usbauto';

class QrPayload {
  QrPayload({
    required this.version,
    required this.sid,
    required this.expiresAt,
    required this.endpoints,
    required this.fingerprint,
    required this.hostRole,
    required this.platform,
    this.flags = const [],
  });

  final int version;
  final Uint8List sid;
  final int expiresAt; // unix seconds
  final List<String> endpoints;
  final Uint8List fingerprint;
  final String hostRole; // sender | receiver
  final String platform;
  final List<String> flags;

  static const _allowed = {'v', 'sid', 'exp', 'ep', 'fp', 'role', 'pf', 'f'};
  static const _required = {'v', 'sid', 'exp', 'ep', 'fp', 'role', 'pf'};

  String toUri() {
    final body = jsonEncode({
      'v': version,
      'sid': b64u(sid),
      'exp': expiresAt,
      'ep': endpoints,
      'fp': b64u(fingerprint),
      'role': hostRole,
      'pf': platform,
      'f': flags,
    });
    final uri = 'ptp://pair?d=${b64u(utf8.encode(body))}';
    assert(uri.length <= 1024);
    return uri;
  }

  static QrPayload parse(String uri, {DateTime? now, bool ignoreExpiry = false}) {
    if (uri.length > 1024) throw PtpException(PtpErrorCode.protocolError, 'QR too long');
    final u = Uri.tryParse(uri);
    if (u == null || u.scheme != 'ptp' || u.host != 'pair') {
      throw PtpException(PtpErrorCode.protocolError, 'not a Phone Transfer Pro code');
    }
    final d = u.queryParameters['d'];
    if (d == null || d.isEmpty) throw PtpException(PtpErrorCode.protocolError, 'missing payload');
    final Object? obj;
    try {
      obj = jsonDecode(utf8.decode(unb64u(d)));
    } on FormatException {
      throw PtpException(PtpErrorCode.protocolError, 'payload not JSON');
    }
    if (obj is! Map<String, dynamic>) throw PtpException(PtpErrorCode.protocolError, 'payload not object');
    if (!_allowed.containsAll(obj.keys) || !obj.keys.toSet().containsAll(_required)) {
      throw PtpException(PtpErrorCode.protocolError, 'unexpected QR fields');
    }
    final v = obj['v'];
    if (v is! int || !supportedVersions.contains(v)) {
      throw PtpException(PtpErrorCode.protocolVersionMismatch, 'QR version $v');
    }
    final exp = obj['exp'];
    if (exp is! int) throw PtpException(PtpErrorCode.protocolError, 'bad exp');
    final nowSec = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    if (!ignoreExpiry && nowSec > exp) throw PtpException(PtpErrorCode.pairingExpired, 'QR code expired');
    final ep = obj['ep'];
    if (ep is! List || ep.isEmpty || ep.length > 8) throw PtpException(PtpErrorCode.protocolError, 'bad endpoints');
    for (final e in ep) {
      Endpoint.parse(e);
    }
    final role = obj['role'];
    final pf = obj['pf'];
    if ((role != 'sender' && role != 'receiver') || !platformIds.contains(pf)) {
      throw PtpException(PtpErrorCode.protocolError, 'bad role/platform');
    }
    final f = obj['f'] ?? <dynamic>[];
    if (f is! List || f.length > 16 || f.any((x) => x is! String || x.length > 32)) {
      throw PtpException(PtpErrorCode.protocolError, 'bad flags');
    }
    return QrPayload(
      version: v,
      sid: unb64u(obj['sid'], length: 16),
      expiresAt: exp,
      endpoints: ep.cast<String>(),
      fingerprint: unb64u(obj['fp'], length: 32),
      hostRole: role as String,
      platform: pf as String,
      flags: f.cast<String>(),
    );
  }
}
