/// QR/session payload (PROTOCOL_v1 §2). Contains no PII, no account credentials, no file names. The optional `ap`
/// field carries the ephemeral name/password of the host's app-only hotspot ("Điểm phát"); it is shown on screen
/// for the other phone to scan and must never be logged.
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

/// Host's app-only hotspot (Android LocalOnlyHotspot): random name/password created by the system for this session.
class HotspotInfo {
  const HotspotInfo(this.ssid, this.psk, this.sec, {this.mode = 'ap', this.band = 'a'});
  final String ssid;
  final String psk;
  final String sec; // wpa2 | wpa3
  final String mode; // p2p (Wi-Fi Direct group) | ap (local-only hotspot)
  final String band; // 5 | 2 | a (unknown / system choice)

  Map<String, Object?> toJson() => {'s': ssid, 'k': psk, 'sec': sec, 'm': mode, 'b': band};

  static HotspotInfo parse(Object? o) {
    if (o is! Map || !{'s', 'k', 'sec', 'm', 'b'}.containsAll(o.keys)) {
      throw PtpException(PtpErrorCode.protocolError, 'bad hotspot info');
    }
    final s = o['s'];
    final k = o['k'];
    final sec = o['sec'];
    if (s is! String || s.isEmpty || utf8.encode(s).length > 32 || s.contains(RegExp(r'[\x00-\x1f]'))) {
      throw PtpException(PtpErrorCode.protocolError, 'bad hotspot name');
    }
    if (k is! String || k.length < 8 || k.length > 63 || k.codeUnits.any((c) => c < 0x20 || c > 0x7e)) {
      throw PtpException(PtpErrorCode.protocolError, 'bad hotspot password');
    }
    if (sec != 'wpa2' && sec != 'wpa3') throw PtpException(PtpErrorCode.protocolError, 'bad hotspot security');
    final m = o['m'] ?? 'ap';
    final b = o['b'] ?? 'a';
    if ((m != 'p2p' && m != 'ap') || (b != '5' && b != '2' && b != 'a')) {
      throw PtpException(PtpErrorCode.protocolError, 'bad hotspot mode/band');
    }
    return HotspotInfo(s, k, sec as String, mode: m as String, band: b as String);
  }

  @override
  String toString() => 'HotspotInfo(<redacted>)'; // never print the password by accident
}

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
    this.ap,
  });

  final int version;
  final Uint8List sid;
  final int expiresAt; // unix seconds
  final List<String> endpoints;
  final Uint8List fingerprint;
  final String hostRole; // sender | receiver
  final String platform;
  final List<String> flags;
  final HotspotInfo? ap;

  QrPayload withEndpoints(List<String> eps) => QrPayload(
      version: version,
      sid: sid,
      expiresAt: expiresAt,
      endpoints: eps,
      fingerprint: fingerprint,
      hostRole: hostRole,
      platform: platform,
      flags: flags,
      ap: ap);

  static const _allowed = {'v', 'sid', 'exp', 'ep', 'fp', 'role', 'pf', 'f', 'ap'};
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
      if (ap != null) 'ap': ap!.toJson(),
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
      ap: obj.containsKey('ap') ? HotspotInfo.parse(obj['ap']) : null,
    );
  }
}
