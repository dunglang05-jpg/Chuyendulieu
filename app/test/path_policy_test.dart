// Decision logic of the "Tự động" (Wi-Fi → USB-C cable) mode. Byte counters here are synthetic inputs to the
// policy, not device measurements; real speeds come only from devices (docs/USB_C_OTG_TEST_REPORT.md).
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_transfer_pro/core/transfer/path_policy.dart';

final t0 = DateTime.utc(2030);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

/// Feeds [mbps] for [ms] milliseconds starting at [startMs] with a counter starting at [startBytes]; returns the end.
int feed(PathPolicy p, int startMs, int ms, double mbps, int startBytes) {
  var b = startBytes;
  for (var t = startMs; t <= startMs + ms; t += 250) {
    p.onBytes(at(t), b);
    b += (mbps * 1e6 * 0.25).round();
  }
  return b;
}

void main() {
  group('RateMeter', () {
    test('reports null until enough real samples, then the windowed rate', () {
      final m = RateMeter();
      expect(m.rate(at(0)), isNull);
      m.add(at(0), 0);
      m.add(at(1000), 10000000);
      expect(m.rate(at(1000)), isNull, reason: 'span < 2 s');
      m.add(at(3000), 30000000);
      expect(m.rate(at(3000)), closeTo(10.0, 0.01));
    });
  });

  group('PathPolicy', () {
    test('no switch while the cable is absent, or while not transferring', () {
      final p = PathPolicy();
      feed(p, 0, 4000, 20, 0);
      expect(p.tick(at(4000), transferring: true), PathAction.none);
      p.onCableState(true);
      expect(p.tick(at(4000), transferring: false), PathAction.none);
      expect(p.path, LinkPath.wifi);
    });

    test('cable plugged → move to cable; cable measured faster → stays on cable', () {
      final p = PathPolicy();
      var b = feed(p, 0, 5000, 20, 0);
      p.onCableState(true);
      expect(p.tick(at(5000), transferring: true), PathAction.toCable);
      expect(p.wifiMbps, closeTo(20, 0.5));
      expect(p.reason, PathReason.cableConnected);
      b = feed(p, 5000, 12000, 35, b);
      expect(p.tick(at(17000), transferring: true), PathAction.none);
      expect(p.path, LinkPath.usb);
      expect(p.cableMbps, closeTo(35, 0.5));
      expect(p.reason, PathReason.cableFaster);
    });

    test('cable measured slower → back to Wi-Fi, and not retried until the cable is replugged', () {
      final p = PathPolicy();
      var b = feed(p, 0, 5000, 40, 0);
      p.onCableState(true);
      expect(p.tick(at(5000), transferring: true), PathAction.toCable);
      b = feed(p, 5000, 12000, 25, b);
      expect(p.tick(at(17000), transferring: true), PathAction.toWifi);
      expect(p.reason, PathReason.cableSlower);
      b = feed(p, 17000, 5000, 40, b);
      expect(p.tick(at(22000), transferring: true), PathAction.none, reason: 'rejected cable is not retried');
      p.onCableState(false);
      p.onCableState(true);
      expect(p.tick(at(22500), transferring: true), PathAction.toCable, reason: 'replug gets a new trial');
    });

    test('no decision before settle + trial, and none without real data (stall)', () {
      final p = PathPolicy();
      feed(p, 0, 5000, 20, 0);
      p.onCableState(true);
      p.tick(at(5000), transferring: true);
      expect(p.tick(at(9000), transferring: true), PathAction.none);
      expect(p.onTrial, isTrue);
      expect(p.tick(at(20000), transferring: true), PathAction.none, reason: 'no samples on the cable yet');
      expect(p.cableMbps, isNull);
    });

    test('Wi-Fi rate unknown (cable plugged right at the start) → cable is kept, never compared to a guess', () {
      final p = PathPolicy();
      p.onCableState(true);
      expect(p.tick(at(0), transferring: true), PathAction.toCable);
      expect(p.reason, PathReason.wifiUnmeasured);
      feed(p, 0, 12000, 5, 0);
      expect(p.tick(at(12000), transferring: true), PathAction.none);
      expect(p.path, LinkPath.usb);
    });

    test('cable unplugged on the cable path → back to Wi-Fi even when not transferring', () {
      final p = PathPolicy();
      p.onCableState(true);
      p.tick(at(0), transferring: true);
      p.onCableState(false);
      expect(p.tick(at(1000), transferring: false), PathAction.toWifi);
      expect(p.reason, PathReason.cableLost);
      expect(p.cableRejected, isFalse);
    });
  });
}
