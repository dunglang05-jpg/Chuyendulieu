// Audit P2-18 (checks after writing) and P1-11 (TLS version policy).
// Timings printed here are from the CI host (GitHub runner), NOT from a phone; they only show the relative cost.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:phone_transfer_pro/core/protocol/codec.dart';
import 'package:phone_transfer_pro/core/protocol/errors.dart';
import 'package:phone_transfer_pro/core/protocol/manifest.dart';
import 'package:phone_transfer_pro/core/session/identity.dart';
import 'package:phone_transfer_pro/core/session/session.dart';
import 'package:phone_transfer_pro/core/transfer/engine.dart';
import 'package:phone_transfer_pro/core/transfer/receiver_store.dart';

import 'loopback_transfer_test.dart' show pair, makeFile, sha, testCaps, dev, yes;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('ptp-verify-'));
  tearDown(() async => tmp.delete(recursive: true));

  group('P2-18 after-write checks', () {
    Future<(Duration, ReceiverStore)> transfer(File f, VerifyMode mode) async {
      final store = ReceiverStore(p.join(tmp.path, 'in-${mode.name}'), JsonCheckpointStore(tmp.path), (_) async => 1 << 40,
          reserve: 0, verify: mode);
      final (h, hc, jc) = await pair();
      final sw = Stopwatch()..start();
      final r = await Future.wait([runReceiver(hc, store), runSender(jc, [FileSource(f.path, f.uri.pathSegments.last, 'videos')])]);
      sw.stop();
      expect(r[0].ok, [0]);
      expect(sha(File(r[0].committedPaths[0]!)), sha(f));
      await h.close();
      return (sw.elapsed, store);
    }

    test('full read-back re-hashes every byte once and reports its cost', () async {
      final f = await makeFile(tmp, 'v.bin', 32 * 1024 * 1024);
      final (tSize, sSize) = await transfer(f, VerifyMode.size);
      final (tFull, sFull) = await transfer(f, VerifyMode.full);
      expect(sSize.verifiedBytes, 0);
      expect(sFull.verifiedBytes, 32 * 1024 * 1024);
      debugPrint('P2-18 CI-host timing, 32 MiB over loopback TLS: size-only ${tSize.inMilliseconds} ms, '
          'full ${tFull.inMilliseconds} ms (read-back ${sFull.verifyTime.inMilliseconds} ms, +${sFull.verifiedBytes} bytes read)');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a file whose bytes on disk differ from what was hashed in flight is rejected, not published', () async {
      final store = ReceiverStore(p.join(tmp.path, 'in'), JsonCheckpointStore(tmp.path), (_) async => 1 << 40,
          reserve: 0, verify: VerifyMode.full);
      final data = utf8.encode('hello phone transfer');
      final m = Manifest.fromJson({
        'transferId': b64u(List<int>.filled(16, 1)),
        'files': [
          {'i': 0, 'path': 'a.txt', 'size': data.length, 'category': 'documents'}
        ],
        'totalBytes': data.length,
      });
      await store.prepare(m, [0]);
      final part = await store.openPart(0, 0);
      await store.write(part, data);
      // Simulate a write-path fault: the bytes on disk change after they were hashed in flight.
      await part.raf.setPosition(0);
      await part.raf.writeFrom(utf8.encode('J'));
      final digest = sha256.convert(data).toString();
      await expectLater(store.commit(part, expectedSha256: digest),
          throwsA(isA<PtpException>().having((e) => e.code, 'code', PtpErrorCode.hashMismatch)));
      expect(File(p.join(tmp.path, 'in', 'documents', 'a.txt')).existsSync(), isFalse);
    });

    test('a truncated file is caught by the size check even without a read-back', () async {
      final store =
          ReceiverStore(p.join(tmp.path, 'in'), JsonCheckpointStore(tmp.path), (_) async => 1 << 40, reserve: 0);
      final m = Manifest.fromJson({
        'transferId': b64u(List<int>.filled(16, 2)),
        'files': [
          {'i': 0, 'path': 'b.txt', 'size': 10, 'category': 'documents'}
        ],
        'totalBytes': 10,
      });
      await store.prepare(m, [0]);
      final part = await store.openPart(0, 0);
      await store.write(part, List<int>.filled(10, 7));
      await part.raf.truncate(4);
      await expectLater(store.commit(part), throwsA(isA<PtpException>().having((e) => e.code, 'code', PtpErrorCode.hashMismatch)));
    });
  });

  group('P1-11 TLS version actually negotiated (openssl s_client against the real PtpHost)', () {
    Future<(bool, String)> probe(int port, List<String> extra) async {
      final r = await Process.run('bash', [
        '-c',
        'echo | timeout 10 openssl s_client -connect 127.0.0.1:$port -brief ${extra.join(' ')} 2>&1',
      ]);
      final out = '${r.stdout}';
      final m = RegExp(r'Protocol version: (\S+)').firstMatch(out);
      return (m != null, m?.group(1) ?? out.split('\n').where((l) => l.contains('error') || l.contains('alert')).take(1).join());
    }

    test('client offering every version gets TLS 1.3; 1.1 is refused; 1.2-only client is still accepted', () async {
      final hasOpenssl = (await Process.run('bash', ['-c', 'command -v openssl'])).exitCode == 0;
      if (!hasOpenssl) {
        markTestSkipped('openssl not installed on this machine');
        return;
      }
      final h = PtpHost(role: 'receiver', device: dev, confirm: yes, caps: testCaps('receiver'), identity: await EphemeralIdentity.generate());
      await h.start();
      final (okDefault, verDefault) = await probe(h.port, []);
      final (ok11, ver11) = await probe(h.port, ['-tls1_1']);
      final (ok12, ver12) = await probe(h.port, ['-tls1_2']);
      debugPrint('P1-11 negotiated: default=$verDefault, tls1_1-only=${ok11 ? ver11 : 'refused'}, '
          'tls1_2-only=${ok12 ? ver12 : 'refused'}');
      expect(okDefault, isTrue);
      expect(verDefault, 'TLSv1.3', reason: 'a modern client always ends up on TLS 1.3');
      expect(ok11, isFalse, reason: 'TLS 1.1 and older are disabled by BoringSSL');
      // Characterisation of the known limitation (THREAT_MODEL.md): Dart's SecureServerSocket has no API to set a
      // minimum version, so a TLS 1.2-only client still completes the handshake. It still cannot impersonate
      // either phone: the joiner pins the certificate from the QR and both sides prove the session id (HMAC).
      // If this ever starts failing, Dart gained a 1.3-only policy: update the docs and remove this expectation.
      expect(ok12, isTrue);
      expect(ver12, 'TLSv1.2');
      await h.close();
    });
  });
}
