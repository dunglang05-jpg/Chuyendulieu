// Two real background-isolate workers pair over TLS on 127.0.0.1 and transfer files: proves the UI-isolate
// <-> worker message protocol (qr, confirm, paired, approve, progress, batch, rpc, receiveDone).
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:phone_transfer_pro/core/domain/capabilities.dart';
import 'package:phone_transfer_pro/core/domain/categories.dart';
import 'package:phone_transfer_pro/core/protocol/constants.dart';
import 'package:phone_transfer_pro/core/protocol/errors.dart';
import 'package:phone_transfer_pro/core/protocol/qr_payload.dart';
import 'package:phone_transfer_pro/core/session/session.dart';
import 'package:phone_transfer_pro/core/transfer/engine.dart';
import 'package:phone_transfer_pro/core/worker/transfer_worker.dart';

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

/// Collects events, auto-answers confirm/approve, and records rpc calls.
class Harness {
  Harness(this.name);
  final String name;
  late TransferWorkerClient client;
  final events = <(String, Object?)>[];
  final rpcCalls = <String>[];
  final _waiters = <String, Completer<Object?>>{};
  bool approveAnswer = true;

  Future<void> start() async {
    client = await TransferWorkerClient.spawn((op, args) async {
      rpcCalls.add(op);
      return op == 'freeBytes' ? 1 << 40 : null;
    });
    client.events.listen((ev) {
      events.add(ev);
      final (type, data) = ev;
      if (type == 'confirm') client.send('confirm', true);
      if (type == 'approve') client.send('approve', approveAnswer);
      _waiters.remove(type)?.complete(data);
    });
  }

  Future<Object?> next(String type) {
    final c = Completer<Object?>();
    _waiters[type] = c;
    return c.future.timeout(const Duration(seconds: 30));
  }
}

String loopback(String uri, int port) {
  final q = QrPayload.parse(uri);
  return QrPayload(
          version: q.version,
          sid: q.sid,
          expiresAt: q.expiresAt,
          endpoints: ['127.0.0.1:$port'],
          fingerprint: q.fingerprint,
          hostRole: q.hostRole,
          platform: q.platform)
      .toUri();
}

Future<File> makeFile(Directory d, String name, int size) async {
  final f = File(p.join(d.path, 'src', name));
  await f.parent.create(recursive: true);
  final r = Random(size);
  await f.writeAsBytes(List<int>.generate(size, (_) => r.nextInt(256)));
  return f;
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('ptp-worker-'));
  tearDown(() async => tmp.delete(recursive: true));

  test('host-receiver and joiner-sender workers transfer files end to end', () async {
    final a = await makeFile(tmp, 'a.jpg', 2 * 1024 * 1024 + 17);
    final b = await makeFile(tmp, 'b.pdf', 4096);
    final rx = Harness('rx');
    final tx = Harness('tx');
    await rx.start();
    await tx.start();

    final qrF = rx.next('qr');
    rx.client.send('host', {'role': 'receiver', 'device': dev, 'caps': caps('receiver')});
    final qr = await qrF as Map<String, Object?>;
    final uri = loopback(qr['uri'] as String, qr['port'] as int);

    final rxPaired = rx.next('paired');
    final txPaired = tx.next('paired');
    tx.client.send('join', {'uri': uri, 'device': dev, 'caps': caps('sender')});
    final pr = await rxPaired as Map<String, Object?>;
    await txPaired;
    expect((pr['plan'] as List).toSet(), containsAll(['photos', 'documents']));
    expect(rx.events.where((e) => e.$1 == 'confirm').length, 1);
    expect(tx.events.where((e) => e.$1 == 'confirm').length, 1);

    final rxDone = rx.next('receiveDone');
    final txBatch = tx.next('batch');
    rx.client.send('receive', {'inbox': p.join(tmp.path, 'inbox'), 'checkpoints': p.join(tmp.path, 'cp'), 'reserve': 0});
    tx.client.send('send', {
      'transferId': null,
      'more': false,
      'items': [
        {'path': a.path, 'relPath': 'DCIM/a.jpg', 'category': 'photos', 'mime': 'image/jpeg', 'mtimeMs': 1, 'token': 't1'},
        {'path': b.path, 'relPath': 'b.pdf', 'category': 'documents', 'mime': null, 'mtimeMs': null, 'token': 't2'},
      ],
    });
    final rep = await txBatch as TransferReport;
    await rxDone;
    expect(rep.ok, [0, 1]);
    final rxRep = rx.events.lastWhere((e) => e.$1 == 'batch').$2 as TransferReport;
    expect(rxRep.ok, [0, 1]);
    expect(sha256.convert(await File(rxRep.committedPaths[0]!).readAsBytes()), sha256.convert(await a.readAsBytes()));
    expect(rx.rpcCalls, contains('freeBytes')); // capacity asked through the UI isolate
    expect(tx.rpcCalls.where((c) => c == 'closeRead').length, greaterThanOrEqualTo(2)); // sources released
    expect(tx.events.any((e) => e.$1 == 'progress'), isTrue);
    expect(rx.events.any((e) => e.$1 == 'approve'), isTrue);
    await rx.client.dispose();
    await tx.client.dispose();
  });

  test('receiver declining the manifest reaches the sender as USER_CANCELLED', () async {
    final a = await makeFile(tmp, 'a.txt', 100);
    final rx = Harness('rx')..approveAnswer = false;
    final tx = Harness('tx');
    await rx.start();
    await tx.start();
    final qrF = rx.next('qr');
    rx.client.send('host', {'role': 'receiver', 'device': dev, 'caps': caps('receiver')});
    final qr = await qrF as Map<String, Object?>;
    final txPaired = tx.next('paired');
    final rxPaired = rx.next('paired');
    tx.client.send('join', {'uri': loopback(qr['uri'] as String, qr['port'] as int), 'device': dev, 'caps': caps('sender')});
    await Future.wait([txPaired, rxPaired]);
    final txErr = tx.next('error');
    rx.client.send('receive', {'inbox': p.join(tmp.path, 'inbox'), 'checkpoints': p.join(tmp.path, 'cp'), 'reserve': 0});
    tx.client.send('send', {
      'transferId': null,
      'more': false,
      'items': [
        {'path': a.path, 'relPath': 'a.txt', 'category': 'documents', 'mime': null, 'mtimeMs': null, 'token': null}
      ],
    });
    final e = await txErr as PtpException;
    expect(e.code, PtpErrorCode.userCancelled);
    await rx.client.dispose();
    await tx.client.dispose();
  });
}
