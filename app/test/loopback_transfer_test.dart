// End-to-end over real TLS sockets on 127.0.0.1 in the Dart VM (no phone needed).
// Run: flutter test test/loopback_transfer_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:phone_transfer_pro/core/domain/capabilities.dart';
import 'package:phone_transfer_pro/core/domain/categories.dart';
import 'package:phone_transfer_pro/core/protocol/codec.dart';
import 'package:phone_transfer_pro/core/protocol/constants.dart';
import 'package:phone_transfer_pro/core/protocol/errors.dart';
import 'package:phone_transfer_pro/core/protocol/qr_payload.dart';
import 'package:phone_transfer_pro/core/session/identity.dart';
import 'package:phone_transfer_pro/core/session/session.dart';
import 'package:phone_transfer_pro/core/transfer/engine.dart';
import 'package:phone_transfer_pro/core/transfer/receiver_store.dart';

Capabilities testCaps(String role) => Capabilities(
      platform: 'desktop_reference',
      role: role,
      osVersion: 'vm',
      appVersion: 'test',
      categories: [
        for (final id in categoryIds)
          CategoryCapability(id, canExport: true, canImport: true, status: SupportStatus.supported)
      ],
    );

const dev = DeviceInfo('VM', 'desktop_reference', 'x');
Future<bool> yes(String sas, DeviceInfo d) async => true;

Future<(PtpHost, PtpChannel, PtpChannel)> pair({String hostRole = 'receiver'}) async {
  final h = PtpHost(role: hostRole, device: dev, confirm: yes, caps: testCaps(hostRole), identity: await EphemeralIdentity.generate());
  await h.start();
  final uri = _loopbackUri(h);
  final jf = joinSession(uri, device: dev, confirm: yes, capsForRole: testCaps);
  final hc = await h.accept();
  return (h, hc, await jf);
}

String _loopbackUri(PtpHost h) {
  final q = h.qr;
  return QrPayload(
          version: q.version,
          sid: q.sid,
          expiresAt: q.expiresAt,
          endpoints: ['127.0.0.1:${h.port}'],
          fingerprint: q.fingerprint,
          hostRole: q.hostRole,
          platform: q.platform)
      .toUri();
}

Future<File> makeFile(Directory d, String name, int size) async {
  final f = File(p.join(d.path, 'src', name));
  await f.parent.create(recursive: true);
  final r = Random(size);
  final sink = f.openWrite();
  var left = size;
  while (left > 0) {
    final n = min(left, 1 << 20);
    sink.add(List<int>.generate(n, (_) => r.nextInt(256)));
    left -= n;
  }
  await sink.close();
  return f;
}

String sha(File f) => sha256.convert(f.readAsBytesSync()).toString();

ReceiverStore storeAt(Directory d) =>
    ReceiverStore(p.join(d.path, 'inbox'), JsonCheckpointStore(d.path), (_) async => 1 << 40, reserve: 0);

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('ptp-dart-'));
  tearDown(() async => tmp.delete(recursive: true));

  for (final hostRole in ['receiver', 'sender']) {
    test('transfer with QR shown by the $hostRole', () async {
      final a = await makeFile(tmp, 'a.jpg', 3000123);
      final b = await makeFile(tmp, 'empty.txt', 0);
      final (h, hc, jc) = await pair(hostRole: hostRole);
      expect(hc.sas, jc.sas);
      final snd = hc.role == 'sender' ? hc : jc;
      final rcv = hc.role == 'sender' ? jc : hc;
      final results = await Future.wait([
        runReceiver(rcv, storeAt(tmp)),
        runSender(snd, [FileSource(a.path, 'DCIM/a.jpg', 'photos'), FileSource(b.path, 'Tài liệu/empty.txt', 'documents')]),
      ]);
      expect(results[1].ok, [0, 1]);
      expect(sha(File(p.join(tmp.path, 'inbox/photos/DCIM/a.jpg'))), sha(a));
      expect(File(p.join(tmp.path, 'inbox/documents/Tài liệu/empty.txt')).lengthSync(), 0);
      await hc.close();
      await jc.close();
      await h.close();
    });
  }

  test('wrong fingerprint is refused before any data is sent', () async {
    final h = PtpHost(role: 'receiver', device: dev, confirm: yes, caps: testCaps('receiver'), identity: await EphemeralIdentity.generate());
    await h.start();
    final q = h.qr;
    final evil = QrPayload(
            version: 1,
            sid: q.sid,
            expiresAt: q.expiresAt,
            endpoints: ['127.0.0.1:${h.port}'],
            fingerprint: randomBytes(32),
            hostRole: 'receiver',
            platform: q.platform)
        .toUri();
    await expectLater(joinSession(evil, device: dev, confirm: yes, capsForRole: testCaps),
        throwsA(isA<PtpException>().having((e) => e.code, 'code', PtpErrorCode.authenticationFailed)));
    expect(h.failures, 0);
    await h.close();
  });

  test('resume after abrupt disconnect continues from the checkpoint', () async {
    final big = await makeFile(tmp, 'big.bin', 40 * 1024 * 1024);
    final (h, hc, jc) = await pair();
    final tid = b64u(randomBytes(16));
    const cancelAt = 25 * 1024 * 1024;
    final sendF = runSender(jc, [FileSource(big.path, 'big.bin', 'videos')], transferId: tid,
        onProgress: (i, done, total, wire) {
      if (wire >= cancelAt) jc.socket.destroy(); // simulate Wi-Fi loss
    });
    final recvF = runReceiver(hc, storeAt(tmp));
    // Capture both outcomes up front so neither error escapes as an unhandled async error.
    Future<Object?> settle(Future<Object?> f) => f.then<Object?>((r) => r, onError: (Object e) => e);
    final first = await Future.wait([settle(recvF), settle(sendF)]);
    expect(first[0], isA<PtpException>());
    expect(first[1], isNot(isA<TransferReport>()));
    h.release();
    final jf = joinSession(_loopbackUri(h), device: dev, confirm: yes, capsForRole: testCaps, resumeToken: jc.resumeToken);
    final hc2 = await h.accept();
    final jc2 = await jf;
    expect(hc2.resumed, isTrue);
    final r = await Future.wait([runReceiver(hc2, storeAt(tmp)), runSender(jc2, [FileSource(big.path, 'big.bin', 'videos')], transferId: tid)]);
    expect(r[1].ok, [0]);
    expect(r[1].wireBytes, lessThan(40 * 1024 * 1024));
    expect(sha(File(p.join(tmp.path, 'inbox/videos/big.bin'))), sha(big));
    await h.close();
  });

  test('path traversal in a manifest is rejected and nothing is written', () async {
    final (h, hc, jc) = await pair();
    unawaited(jc.writer.control({
      't': 'manifest',
      'transferId': b64u(randomBytes(16)),
      'totalBytes': 4,
      'files': [
        {'i': 0, 'path': '../../evil.sh', 'size': 4, 'category': 'documents'}
      ]
    }));
    await expectLater(runReceiver(hc, storeAt(tmp)),
        throwsA(isA<PtpException>().having((e) => e.code, 'code', PtpErrorCode.manifestInvalid)));
    expect(tmp.listSync(recursive: true).where((e) => e.path.endsWith('evil.sh')), isEmpty);
    await h.close();
  });

  test('receiver without enough space refuses before any data moves', () async {
    final f = await makeFile(tmp, 'x.bin', 1000);
    final (h, hc, jc) = await pair();
    final store = ReceiverStore(p.join(tmp.path, 'inbox'), JsonCheckpointStore(tmp.path), (_) async => 10, reserve: 0);
    Future<Object?> settle(Future<Object?> f) => f.then<Object?>((r) => r, onError: (Object e) => e);
    final r = await Future.wait([settle(runReceiver(hc, store)), settle(runSender(jc, [FileSource(f.path, 'x.bin', 'documents')]))]);
    for (final x in r) {
      expect(x, isA<PtpException>().having((e) => e.code, 'code', PtpErrorCode.storageInsufficient));
    }
    expect(File(p.join(tmp.path, 'inbox/documents/x.bin')).existsSync(), isFalse);
    await h.close();
  });

  test('cancel by the sender stops both sides and leaves no final file', () async {
    final big = await makeFile(tmp, 'big.bin', 20 * 1024 * 1024);
    final (h, hc, jc) = await pair();
    final token = CancelToken();
    Future<Object?> settle(Future<Object?> f) => f.then<Object?>((r) => r, onError: (Object e) => e);
    final r = await Future.wait([
      settle(runReceiver(hc, storeAt(tmp))),
      settle(runSender(jc, [FileSource(big.path, 'big.bin', 'videos')], cancel: token, onProgress: (i, d, t, w) {
        if (w > 5 * 1024 * 1024) token.cancel();
      })),
    ]);
    for (final x in r) {
      expect(x, isA<PtpException>().having((e) => e.code, 'code', PtpErrorCode.userCancelled));
    }
    expect(File(p.join(tmp.path, 'inbox/videos/big.bin')).existsSync(), isFalse);
    await h.close();
  });
}
