// Audit P1-10: continuing after an app kill / reboot. These tests run two real TLS sessions on one machine and the
// storage code against temp folders. They do NOT prove behaviour after Android/iOS really kill the process or the
// phone reboots, nor that Keystore/Keychain work on a device (docs/REMAINING_HARDENING_REPORT.md).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:phone_transfer_pro/app/continuation_repo.dart';
import 'package:phone_transfer_pro/core/protocol/codec.dart';
import 'package:phone_transfer_pro/core/session/continuation.dart';
import 'package:phone_transfer_pro/core/transfer/engine.dart';
import 'package:phone_transfer_pro/core/transfer/receiver_store.dart';

import 'loopback_transfer_test.dart' show pair, makeFile, sha;

ContinuationRecord rec(String role, Uint8List key, {String id = 'AAAAAAAAAAAAAAAAAAAAAA', DateTime? at}) =>
    ContinuationRecord(
      id: id,
      key: key,
      role: role,
      peerName: 'peer',
      peerPlatform: 'android',
      createdAt: at ?? DateTime.now(),
      transferIds: ['BBBBBBBBBBBBBBBBBBBBBB'],
    );

class MapVault implements SecureVault {
  final m = <String, Uint8List>{};
  @override
  Future<void> put(String name, Uint8List secret) async => m[name] = secret;
  @override
  Future<Uint8List?> get(String name) async => m[name];
  @override
  Future<void> delete(String name) async => m.remove(name);
}

/// Pairs (host = receiver, joiner = sender) and runs the exchange on both ends at once.
Future<(ContinuationOutcome, ContinuationOutcome)> negotiate(
    List<ContinuationRecord> receiverHas, List<ContinuationRecord> senderHas) async {
  final (h, hc, jc) = await pair();
  final r = await Future.wait([negotiateContinuation(hc, receiverHas), negotiateContinuation(jc, senderHas)]);
  await hc.close();
  await jc.close();
  await h.close();
  return (r[0], r[1]);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('ptp-cont-'));
  tearDown(() async => tmp.delete(recursive: true));

  group('negotiation', () {
    test('both phones hold the same record → both continue it', () async {
      final k = randomBytes(32);
      final (r, s) = await negotiate([rec('receiver', k)], [rec('sender', k)]);
      expect(r.continued, isTrue);
      expect(s.continued, isTrue);
      expect(r.record.id, s.record.id);
      expect(r.record.transferIds, ['BBBBBBBBBBBBBBBBBBBBBB']);
    });

    test('nothing remembered → no continuation, both derive the SAME fresh key and id', () async {
      final (r, s) = await negotiate([], []);
      expect(r.continued || s.continued, isFalse);
      expect(r.record.key, s.record.key);
      expect(r.record.id, s.record.id);
      expect(r.record.role, 'receiver');
      expect(s.record.role, 'sender');
    });

    test('only one phone remembers it (other app reinstalled / data cleared) → no continuation on either', () async {
      final (r, s) = await negotiate([rec('receiver', randomBytes(32))], []);
      expect(r.continued, isFalse);
      expect(s.continued, isFalse);
      expect(r.record.id, s.record.id);
    });

    test('same id, different key (forged or mixed-up record) → refused by both', () async {
      final (r, s) = await negotiate([rec('receiver', randomBytes(32))], [rec('sender', randomBytes(32))]);
      expect(r.continued, isFalse);
      expect(s.continued, isFalse);
    });

    test('a record older than 24 h is never offered', () async {
      final k = randomBytes(32);
      final old = DateTime.now().subtract(const Duration(hours: 25));
      final (r, s) = await negotiate([rec('receiver', k, at: old)], [rec('sender', k)]);
      expect(r.continued || s.continued, isFalse);
    });

    test('a record kept for the other role does not match', () async {
      final k = randomBytes(32);
      final (r, s) = await negotiate([rec('sender', k)], [rec('receiver', k)]);
      expect(r.continued || s.continued, isFalse);
    });

    test('proofs are bound to the session: a proof from one session is wrong in another (no replay)', () {
      final k = randomBytes(32);
      final b1 = sessionBinding(randomBytes(16), randomBytes(32), randomBytes(16), randomBytes(16));
      final b2 = sessionBinding(randomBytes(16), randomBytes(32), randomBytes(16), randomBytes(16));
      final label = utf8.encode('ptp1/cont/offer');
      expect(continuationProof(k, label, 'sender', b1), isNot(continuationProof(k, label, 'sender', b2)));
      expect(continuationProof(k, label, 'sender', b1), isNot(continuationProof(k, label, 'receiver', b1)));
    });
  });

  group('checkpoints', () {
    test('MAC-protected checkpoint: round trip, tampering and a wrong key are rejected', () async {
      final k = randomBytes(32);
      final rejected = <String>[];
      final store = JsonCheckpointStore(tmp.path, macKey: k, onRejected: rejected.add);
      await store.save('T', {'transferId': 'T', 'files': {'0': {'durable': 8388608}}});
      expect((await store.load('T'))['files'], {'0': {'durable': 8388608}});

      final f = File(p.join(tmp.path, 'T.state.json'));
      await f.writeAsString((await f.readAsString()).replaceFirst('8388608', '9999999'));
      expect(await store.load('T'), isEmpty);
      await f.writeAsString('{"body": trunc');
      expect(await store.load('T'), isEmpty);
      expect(rejected, ['mac', 'corrupt']);

      await store.save('T', {'transferId': 'T', 'files': {}});
      expect(await JsonCheckpointStore(tmp.path, macKey: randomBytes(32)).load('T'), isEmpty);
    });

    test('partial data of a transfer the phones did not agree to continue is not reused', () async {
      final video = await makeFile(tmp, 'v.mp4', 9 * 1024 * 1024 + 5);
      const tid = 'CCCCCCCCCCCCCCCCCCCCCC';
      ReceiverStore mk(bool allow) => ReceiverStore(p.join(tmp.path, 'inbox'), JsonCheckpointStore(tmp.path), (_) async => 1 << 40,
          reserve: 0, resumeAllowed: (_) => allow);

      var (h, hc, jc) = await pair();
      Future<Object?> settle(Future<Object?> f) => f.then<Object?>((r) => r, onError: (Object e) => e);
      // First session dies after the 8 MiB checkpoint, like an app that was killed: the socket just vanishes.
      var killed = false;
      await Future.wait([
        settle(runReceiver(hc, mk(false))),
        settle(runSender(jc, [FileSource(video.path, 'v.mp4', 'videos')], transferId: tid, onProgress: (i, d, t, w) {
          if (!killed && w > 8 * 1024 * 1024 + 512 * 1024) {
            killed = true;
            jc.socket.destroy();
          }
        })),
      ]).timeout(const Duration(seconds: 60), onTimeout: () => throw StateError('first session hung'));
      await hc.close();
      await h.close();

      (h, hc, jc) = await pair();
      final starts = <int>[];
      final r = await Future.wait([
        runReceiver(hc, mk(false)),
        runSender(jc, [FileSource(video.path, 'v.mp4', 'videos')], transferId: tid, onProgress: (i, d, t, w) {
          if (starts.isEmpty) starts.add(d - w);
        }),
      ]).timeout(const Duration(seconds: 60), onTimeout: () => throw StateError('second session hung'));
      expect(starts.single, 0, reason: 'restarted from 0: the earlier partial was not trusted');
      expect(sha(File(r[0].committedPaths[0]!)), sha(video));
      await h.close();
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('repository', () {
    test('save → load; tampered record, missing key and expired record are dropped', () async {
      final vault = MapVault();
      final repo = ContinuationRepo(p.join(tmp.path, 'cont'), vault);
      final good = rec('sender', randomBytes(32), id: 'DDDDDDDDDDDDDDDDDDDDDD')..plan = {'batches': [], 'index': 0};
      await repo.save(good);
      final loaded = await repo.loadAll();
      expect(loaded.single.id, good.id);
      expect(loaded.single.key, good.key);
      expect(loaded.single.plan, {'batches': [], 'index': 0});
      expect(File(p.join(tmp.path, 'cont', 'cont_DDDDDDDDDDDDDDDDDDDDDD.json')).readAsStringSync(),
          isNot(contains(b64u(good.key))), reason: 'the key never goes into the JSON file');

      final f = File(p.join(tmp.path, 'cont', 'cont_DDDDDDDDDDDDDDDDDDDDDD.json'));
      await f.writeAsString(f.readAsStringSync().replaceFirst('"index":0', '"index":3'));
      expect(await repo.loadAll(), isEmpty);
      expect(vault.m, isEmpty, reason: 'a tampered record is deleted with its key');

      final keyless = rec('sender', randomBytes(32), id: 'EEEEEEEEEEEEEEEEEEEEEE');
      await repo.save(keyless);
      vault.m.clear();
      expect(await repo.loadAll(), isEmpty);

      final old = rec('sender', randomBytes(32), id: 'FFFFFFFFFFFFFFFFFFFFFF', at: DateTime.now().subtract(const Duration(hours: 30)));
      await repo.save(old);
      expect(await repo.loadAll(), isEmpty);
      expect(Directory(p.join(tmp.path, 'cont')).listSync(), isEmpty);
    });
  });
}
