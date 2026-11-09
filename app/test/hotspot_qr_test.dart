// "Điểm phát" (direct phone-to-phone Wi-Fi): QR field validation and endpoint ordering. Runs in the Dart VM; the
// Android/iOS hotspot APIs themselves are NOT tested here (they need real phones, see docs/HOTSPOT.md).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_transfer_pro/core/protocol/codec.dart';
import 'package:phone_transfer_pro/core/protocol/errors.dart';
import 'package:phone_transfer_pro/core/protocol/qr_payload.dart';
import 'package:phone_transfer_pro/core/session/identity.dart';
import 'package:phone_transfer_pro/core/session/session.dart';

import 'loopback_transfer_test.dart' show dev, testCaps, yes;

QrPayload _qr({HotspotInfo? ap, List<String>? eps}) => QrPayload(
      version: 1,
      sid: Uint8List.fromList(List.filled(16, 3)),
      expiresAt: DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
      endpoints: eps ?? const ['192.168.49.1:40001'],
      fingerprint: Uint8List.fromList(List.filled(32, 7)),
      hostRole: 'receiver',
      platform: 'android',
      ap: ap,
    );

/// Re-encodes the QR body with [patch] applied to the `ap` object (to feed malformed values to the parser).
String _withAp(Object? ap) {
  final u = Uri.parse(_qr(ap: const HotspotInfo('AndroidShare_1234', 'abcd1234efgh', 'wpa2')).toUri());
  final body = jsonDecode(utf8.decode(unb64u(u.queryParameters['d']!))) as Map<String, Object?>;
  body['ap'] = ap;
  return 'ptp://pair?d=${b64u(utf8.encode(jsonEncode(body)))}';
}

void main() {
  test('round trip keeps the hotspot name, password and security', () {
    final q = QrPayload.parse(_qr(ap: const HotspotInfo('AndroidShare_1234', 'abcd1234efgh', 'wpa3')).toUri());
    expect(q.ap, isNotNull);
    expect(q.ap!.ssid, 'AndroidShare_1234');
    expect(q.ap!.psk, 'abcd1234efgh');
    expect(q.ap!.sec, 'wpa3');
  });

  test('mode and band survive the round trip; older QR without them defaults to ap / unknown band', () {
    final q = QrPayload.parse(
        _qr(ap: const HotspotInfo('DIRECT-ab-ChuyenDL', 'abcd1234efgh', 'wpa2', mode: 'p2p', band: '5')).toUri());
    expect(q.ap!.mode, 'p2p');
    expect(q.ap!.band, '5');
    final old = QrPayload.parse(_withAp({'s': 'AndroidShare_1', 'k': 'abcd1234', 'sec': 'wpa2'}));
    expect(old.ap!.mode, 'ap');
    expect(old.ap!.band, 'a');
  });

  test('QR without the field (older app / plain Wi-Fi) has no hotspot', () {
    expect(QrPayload.parse(_qr().toUri()).ap, isNull);
  });

  test('largest allowed values still fit the 1024-char QR limit with 8 endpoints', () {
    final q = _qr(
      ap: HotspotInfo('S' * 32, 'k' * 63, 'wpa2', mode: 'p2p', band: '5'),
      eps: List.generate(8, (i) => '192.168.100.10$i:65535'),
    );
    expect(q.toUri().length, lessThanOrEqualTo(1024));
    expect(QrPayload.parse(q.toUri()).ap!.ssid, 'S' * 32);
  });

  test('malformed hotspot values are rejected', () {
    final bad = <Object?>[
      'x',
      {'s': '', 'k': 'abcd1234', 'sec': 'wpa2'},
      {'s': 'S' * 33, 'k': 'abcd1234', 'sec': 'wpa2'},
      {'s': 'ok', 'k': 'short', 'sec': 'wpa2'},
      {'s': 'ok', 'k': 'k' * 64, 'sec': 'wpa2'},
      {'s': 'ok', 'k': 'abcd1234', 'sec': 'wep'},
      {'s': 'ok', 'k': 'abcd\n1234', 'sec': 'wpa2'},
      {'s': 'a\u0000b', 'k': 'abcd1234', 'sec': 'wpa2'},
      {'s': 'ok', 'k': 'abcd1234', 'sec': 'wpa2', 'extra': 1},
      {'s': 'ok', 'k': 'abcd1234', 'sec': 'wpa2', 'm': 'wifi'},
      {'s': 'ok', 'k': 'abcd1234', 'sec': 'wpa2', 'b': '6'},
    ];
    for (final b in bad) {
      expect(() => QrPayload.parse(_withAp(b)), throwsA(isA<PtpException>()), reason: '$b');
    }
  });

  test('toString never shows the password', () {
    expect(const HotspotInfo('n', 'secret-pass', 'wpa2').toString(), isNot(contains('secret-pass')));
  });

  test('host advertises the hotspot address first and carries the hotspot in its QR', () async {
    final h = PtpHost(
      role: 'receiver',
      device: dev,
      confirm: yes,
      caps: testCaps('receiver'),
      identity: await EphemeralIdentity.generate(),
      ap: const HotspotInfo('AndroidShare_1234', 'abcd1234efgh', 'wpa2'),
      preferredHosts: const ['192.168.49.1', 'not-an-ip'],
    );
    await h.start();
    try {
      expect(h.endpoints.first, '192.168.49.1:${h.port}');
      expect(h.endpoints.where((e) => e.startsWith('not-an-ip')), isEmpty);
      expect(h.endpoints.length, lessThanOrEqualTo(8));
      final q = QrPayload.parse(h.qr.toUri());
      expect(q.ap!.ssid, 'AndroidShare_1234');
      expect(q.endpoints.first, '192.168.49.1:${h.port}');
    } finally {
      await h.close();
    }
  });

  test('withEndpoints keeps everything else, including the hotspot', () {
    final q = _qr(ap: const HotspotInfo('AndroidShare_1234', 'abcd1234efgh', 'wpa2'));
    final r = QrPayload.parse(q.withEndpoints(['10.0.0.1:1', ...q.endpoints]).toUri());
    expect(r.endpoints, ['10.0.0.1:1', '192.168.49.1:40001']);
    expect(r.ap!.psk, 'abcd1234efgh');
    expect(r.sid, q.sid);
  });
}
