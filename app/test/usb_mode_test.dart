// USB-cable mode on the Dart side: the host must be reachable ONLY through 127.0.0.1 (the native USB bridge),
// and the QR carries the non-sensitive 'usb' flag. The cable itself is not exercised here (needs two phones).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_transfer_pro/core/domain/capabilities.dart';
import 'package:phone_transfer_pro/core/domain/categories.dart';
import 'package:phone_transfer_pro/core/protocol/constants.dart';
import 'package:phone_transfer_pro/core/protocol/qr_payload.dart';
import 'package:phone_transfer_pro/core/session/identity.dart';
import 'package:phone_transfer_pro/core/session/session.dart';

Capabilities caps(String role) => Capabilities(
      platform: 'desktop_reference',
      role: role,
      osVersion: 'vm',
      appVersion: 'test',
      categories: [
        for (final id in categoryIds) CategoryCapability(id, canExport: true, canImport: true, status: SupportStatus.supported)
      ],
    );

const dev = DeviceInfo('VM', 'desktop_reference', 'x');
Future<bool> yes(String sas, DeviceInfo d) async => true;

void main() {
  test('loopback-only host advertises 127.0.0.1, carries the usb flag and pairs through loopback', () async {
    final h = PtpHost(
        role: 'receiver',
        device: dev,
        confirm: yes,
        caps: caps('receiver'),
        identity: await EphemeralIdentity.generate(),
        loopbackOnly: true,
        flags: const ['usb']);
    await h.start();
    expect(h.endpoints, ['127.0.0.1:${h.port}']);
    final qr = QrPayload.parse(h.qr.toUri());
    expect(qr.flags, ['usb']);
    final jf = joinSession(h.qr.toUri(), device: dev, confirm: yes, capsForRole: caps);
    final hc = await h.accept();
    final jc = await jf;
    expect(hc.sas, jc.sas);
    await hc.close();
    await jc.close();
    await h.close();
  });

  test('loopback-only host refuses connections from the real network interface (no Wi-Fi fallback)', () async {
    final h = PtpHost(
        role: 'receiver',
        device: dev,
        confirm: yes,
        caps: caps('receiver'),
        identity: await EphemeralIdentity.generate(),
        loopbackOnly: true);
    await h.start();
    final lan = await localEndpoints(h.port);
    final external = lan.where((e) => !e.startsWith('127.')).toList();
    if (external.isEmpty) {
      debugPrint('no non-loopback IPv4 interface on this machine; check skipped');
    } else {
      final ep = Endpoint.parse(external.first);
      await expectLater(Socket.connect(ep.address, ep.port, timeout: const Duration(seconds: 3)),
          throwsA(isA<SocketException>()));
    }
    await h.close();
  });

  test('default (Wi-Fi) host still listens on all interfaces', () async {
    final h = PtpHost(
        role: 'receiver', device: dev, confirm: yes, caps: caps('receiver'), identity: await EphemeralIdentity.generate());
    await h.start();
    final external = (await localEndpoints(h.port)).where((e) => !e.startsWith('127.')).toList();
    if (external.isEmpty) {
      debugPrint('no non-loopback IPv4 interface on this machine; check skipped');
    } else {
      final ep = Endpoint.parse(external.first);
      final s = await Socket.connect(ep.address, ep.port, timeout: const Duration(seconds: 3));
      s.destroy();
    }
    expect(protocolVersion, 1);
    await h.close();
  });
}
