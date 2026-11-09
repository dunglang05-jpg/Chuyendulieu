// Off-isolate SHA-256 (device test 2026-11-09): the digest must equal the inline one byte for byte, also with
// several files hashed at once, and a full transfer with the service on both sides must still verify.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:phone_transfer_pro/core/transfer/engine.dart';
import 'package:phone_transfer_pro/core/transfer/hash_service.dart';

import 'loopback_transfer_test.dart' show makeFile, pair, sha, storeAt;

Uint8List _bytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  test('service digest equals sha256 for chunked input, several files interleaved', () async {
    final svc = await HashService.spawn();
    try {
      final a = _bytes(3 * 1024 * 1024 + 17, 1);
      final b = _bytes(2 * 1024 * 1024, 2);
      final ha = svc.open(a.length);
      final hb = svc.open(b.length);
      expect(ha, isNot(isA<InlineSha256>()));
      for (var off = 0; off < a.length; off += 700000) {
        ha.add(Uint8List.sublistView(a, off, min(off + 700000, a.length)));
        if (off < b.length) hb.add(Uint8List.sublistView(b, off, min(off + 700000, b.length)));
      }
      expect(await hb.digest(), sha256.convert(b).toString());
      expect(await ha.digest(), sha256.convert(a).toString());
    } finally {
      svc.close();
    }
  });

  test('small files stay inline; empty input hashes like sha256 of nothing', () async {
    final svc = await HashService.spawn();
    try {
      final h = svc.open(1000);
      expect(h, isA<InlineSha256>());
      h.add(_bytes(1000, 3));
      expect(await h.digest(), sha256.convert(_bytes(1000, 3)).toString());
      final empty = svc.open(HashService.offThreadMin);
      expect(await empty.digest(), sha256.convert(const <int>[]).toString());
    } finally {
      svc.close();
    }
  });

  test('closing the service fails pending digests instead of hanging', () async {
    final svc = await HashService.spawn();
    final h = svc.open(HashService.offThreadMin * 4);
    h.add(_bytes(1024, 4));
    svc.close();
    await expectLater(h.digest(), throwsA(isA<StateError>()));
  });

  test('full transfer verifies with off-isolate hashing on both sides', () async {
    final tmp = await Directory.systemTemp.createTemp('ptp-hash-');
    try {
      final big = await makeFile(tmp, 'big.bin', 9 * 1024 * 1024 + 5);
      final small = await makeFile(tmp, 's.jpg', 12345);
      final (h, hc, jc) = await pair();
      final svcS = await HashService.spawn();
      final svcR = await HashService.spawn();
      final store = storeAt(tmp)..hashes = svcR;
      final results = await Future.wait([
        runReceiver(hc, store),
        runSender(jc, [FileSource(big.path, 'big.bin', 'videos'), FileSource(small.path, 's.jpg', 'photos')],
            hashes: svcS),
      ]);
      expect(results[1].ok, [0, 1]);
      expect(sha(File(p.join(tmp.path, 'inbox/videos/big.bin'))), sha(big));
      svcS.close();
      svcR.close();
      await hc.close();
      await jc.close();
      await h.close();
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}
