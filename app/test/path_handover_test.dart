// "Tự động" path switch, end to end on one machine: two real worker isolates, real TLS, a real file.
// Path A ("Wi-Fi") and path B ("cable") are two local TCP forwarders in front of the same host port, which is
// exactly what the native USB bridge is (a TCP forwarder over the cable). Mid-file, the joiner switches to B with
// the same 'dial' command the controller uses; PTP/1 resume must finish the file on B with a matching SHA-256.
// This proves the session/resume mechanics only. It says nothing about cable speed or real USB hardware.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:phone_transfer_pro/core/domain/capabilities.dart';
import 'package:phone_transfer_pro/core/domain/categories.dart';
import 'package:phone_transfer_pro/core/protocol/codec.dart';
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

/// Plain TCP forwarder 127.0.0.1:port → 127.0.0.1:target, optionally throttled (client → target direction).
class Forwarder {
  Forwarder(this.target, {this.bytesPerSecond});
  final int target;
  final int? bytesPerSecond;
  late ServerSocket _server;
  int forwarded = 0;
  final _open = <Socket>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((client) async {
      final up = await Socket.connect(InternetAddress.loopbackIPv4, target);
      _open.addAll([client, up]);
      late StreamSubscription<Uint8List> sub;
      sub = client.listen((data) {
        forwarded += data.length;
        up.add(data);
        final bps = bytesPerSecond;
        if (bps != null) {
          sub.pause();
          Future<void>.delayed(Duration(microseconds: data.length * 1000000 ~/ bps), sub.resume);
        }
      }, onDone: up.destroy, onError: (Object _) => up.destroy());
      up.listen(client.add, onDone: client.destroy, onError: (Object _) => client.destroy());
    });
  }

  Future<void> close() async {
    for (final s in _open) {
      s.destroy();
    }
    await _server.close();
  }
}

String withEndpoints(String uri, List<String> eps) {
  final q = QrPayload.parse(uri);
  return QrPayload(
          version: q.version,
          sid: q.sid,
          expiresAt: q.expiresAt,
          endpoints: eps,
          fingerprint: q.fingerprint,
          hostRole: q.hostRole,
          platform: q.platform,
          flags: const [usbAutoFlag])
      .toUri();
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('ptp-handover-'));
  tearDown(() async => tmp.delete(recursive: true));

  test('mid-file switch from path A to path B resumes the same session and the file verifies', () async {
    const size = 24 * 1024 * 1024 + 123;
    final src = File(p.join(tmp.path, 'src', 'VID_1.mp4'));
    await src.parent.create(recursive: true);
    final r = Random(42);
    await src.writeAsBytes(Uint8List.fromList(List<int>.generate(size, (_) => r.nextInt(256))));

    final rx = await TransferWorkerClient.spawn((op, args) async => op == 'freeBytes' ? 1 << 40 : null);
    final tx = await TransferWorkerClient.spawn((op, args) async => null);
    final transferId = b64u(Uint8List.fromList(List<int>.filled(16, 7)));
    final rxCmd = {'inbox': p.join(tmp.path, 'inbox'), 'checkpoints': p.join(tmp.path, 'cp'), 'reserve': 0};
    final sendCmd = {
      'transferId': transferId,
      'more': false,
      'items': [
        {'path': src.path, 'relPath': 'DCIM/VID_1.mp4', 'category': 'videos', 'mime': 'video/mp4', 'mtimeMs': 1, 'token': null}
      ],
    };

    final qr = Completer<Map<String, Object?>>();
    final txPaired = <Map<String, Object?>>[];
    final rxPaired = <Map<String, Object?>>[];
    final txBatch = Completer<TransferReport>();
    final rxBatch = Completer<TransferReport>();
    final rxDone = Completer<void>();
    var confirms = 0;
    var switched = false;
    late Forwarder a;
    late Forwarder b;
    String? uriB;

    rx.events.listen((ev) {
      final (type, data) = ev;
      switch (type) {
        case 'qr':
          qr.complete(data as Map<String, Object?>);
        case 'confirm':
          confirms++;
          rx.send('confirm', true);
        case 'approve':
          rx.send('approve', true);
        case 'paired':
          rxPaired.add(data as Map<String, Object?>);
          rx.send('receive', rxCmd); // first pairing and every resume, like the controller
        case 'error':
          final e = data as PtpException;
          if (e.code.resumable) rx.send('reconnect');
        case 'batch':
          if (!rxBatch.isCompleted) rxBatch.complete(data as TransferReport);
        case 'receiveDone':
          if (!rxDone.isCompleted) rxDone.complete();
      }
    });
    tx.events.listen((ev) {
      final (type, data) = ev;
      switch (type) {
        case 'confirm':
          confirms++;
          tx.send('confirm', true);
        case 'paired':
          txPaired.add(data as Map<String, Object?>);
          tx.send('send', sendCmd); // same transferId → receiver resumes from its checkpoint
        case 'progress':
          final m = data as Map<String, Object?>;
          if (!switched && (m['wire'] as int) >= 4 * 1024 * 1024) {
            switched = true;
            tx.send('dial', {'uri': uriB, 'drop': true, 'to': 'usb'});
          }
        case 'error':
          final e = data as PtpException;
          if (e.code.resumable) tx.send('reconnect');
        case 'batch':
          if (!txBatch.isCompleted) txBatch.complete(data as TransferReport);
      }
    });

    rx.send('host', {'role': 'receiver', 'device': dev, 'caps': caps('receiver'), 'flags': const [usbAutoFlag]});
    final q = await qr.future.timeout(const Duration(seconds: 20));
    final hostPort = q['port'] as int;
    a = Forwarder(hostPort, bytesPerSecond: 6 * 1000 * 1000); // slow path, so the switch lands mid-file
    b = Forwarder(hostPort);
    await a.start();
    await b.start();
    final uriA = withEndpoints(q['uri'] as String, ['127.0.0.1:${a.port}']);
    uriB = withEndpoints(q['uri'] as String, ['127.0.0.1:${b.port}', '127.0.0.1:${a.port}']);

    tx.send('join', {'uri': uriA, 'device': dev, 'caps': caps('sender')});
    final rep = await txBatch.future.timeout(const Duration(seconds: 90));
    await rxDone.future.timeout(const Duration(seconds: 30));
    final rxRep = await rxBatch.future;

    expect(switched, isTrue);
    expect(confirms, 2, reason: 'the 6-digit confirmation happens once per device, not again after the switch');
    expect(txPaired.length, 2);
    expect(txPaired.last['resumed'], isTrue);
    expect(rxPaired.last['resumed'], isTrue);
    expect(b.forwarded, greaterThan(1024 * 1024), reason: 'the rest of the file went over path B');
    expect(a.forwarded, lessThan(size), reason: 'path A did not carry the whole file');
    expect(rep.ok, [0]);
    expect(rxRep.ok, [0]);
    final got = await File(rxRep.committedPaths[0]!).readAsBytes();
    expect(got.length, size);
    expect(sha256.convert(got), sha256.convert(await src.readAsBytes()));

    await rx.dispose();
    await tx.dispose();
    await a.close();
    await b.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
