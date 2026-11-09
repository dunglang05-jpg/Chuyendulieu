/// "Tự động" transport (Android ↔ Android): start on Wi-Fi; when a USB-C cable link comes up mid-transfer, move the
/// session onto the cable, MEASURE the cable for a trial window and go back to Wi-Fi if the cable turned out slower.
///
/// Pure logic (no sockets, no timers, injected clock) so every decision is unit-tested. The controller feeds it the
/// real byte counter and the real native cable state; it never guesses a speed. The switch itself reuses PTP/1
/// resume (same session, TLS re-pinned, resume proof), so the cable stays untrusted exactly like Wi-Fi.
library;

/// Byte-rate over a sliding window, from real progress samples.
class RateMeter {
  RateMeter({this.window = const Duration(seconds: 5)});
  final Duration window;
  final List<(DateTime, int)> _samples = [];

  void reset() => _samples.clear();

  /// [bytes] is a monotonically increasing counter (bytes moved so far).
  void add(DateTime at, int bytes) {
    _samples.add((at, bytes));
    final cutoff = at.subtract(window * 2);
    while (_samples.length > 2 && _samples.first.$1.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  /// MB/s over the last [window]; null until at least [minSpan] of samples exist (no invented numbers).
  double? rate(DateTime now, {Duration minSpan = const Duration(seconds: 2)}) {
    final from = now.subtract(window);
    final inWin = _samples.where((s) => !s.$1.isBefore(from)).toList();
    if (inWin.length < 2) return null;
    final span = inWin.last.$1.difference(inWin.first.$1);
    if (span < minSpan) return null;
    final bytes = inWin.last.$2 - inWin.first.$2;
    if (bytes < 0) return null;
    return bytes / 1e6 / (span.inMilliseconds / 1000);
  }
}

enum LinkPath { wifi, usb }

enum PathAction { none, toCable, toWifi }

/// Why the last switch happened — shown to the user and logged (no personal data).
enum PathReason { none, cableConnected, cableSlower, cableLost, cableFaster, wifiUnmeasured, cableNoData }

class PathPolicy {
  PathPolicy({
    this.settle = const Duration(seconds: 3),
    this.trial = const Duration(seconds: 8),
    this.slowerRatio = 0.85,
    this.noDataGrace = const Duration(seconds: 10),
  });

  /// Extra time after settle + trial before a cable that moved no data at all is given up (device test 2026-11-09:
  /// the session moved to the cable, nothing flowed, and the old policy reported "0.0 MB/s, slower than Wi-Fi").
  final Duration noDataGrace;

  /// Below this the cable is treated as not carrying data rather than as "slower".
  static const double noDataMbps = 0.05;

  /// Ignore the first seconds after a switch (TLS handshake, resume, TCP ramp-up).
  final Duration settle;

  /// Measuring window on the cable before deciding to keep it.
  final Duration trial;

  /// Cable is "slower" if its measured rate is below this fraction of the Wi-Fi rate measured just before.
  final double slowerRatio;

  LinkPath path = LinkPath.wifi;
  bool cableUp = false;

  /// Set when the cable was measured slower; cleared when the cable is unplugged (a replug gets a new trial).
  bool cableRejected = false;
  double? wifiMbps;
  double? cableMbps;
  DateTime? _switchedAt;
  PathReason reason = PathReason.none;
  final RateMeter meter = RateMeter();

  /// New session: forget everything (cable state, measurements, rejection).
  void reset() {
    path = LinkPath.wifi;
    cableUp = false;
    cableRejected = false;
    wifiMbps = null;
    cableMbps = null;
    _switchedAt = null;
    reason = PathReason.none;
    meter.reset();
  }

  bool get onTrial => path == LinkPath.usb && _switchedAt != null && cableMbps == null;

  void onBytes(DateTime at, int bytes) => meter.add(at, bytes);

  void onCableState(bool up) {
    if (!up && cableUp) cableRejected = false;
    cableUp = up;
  }

  /// Called often (e.g. every 500 ms) while data is flowing. [transferring] is false during selection, approval,
  /// pause, reconnect — switching then would only disturb the session, so nothing happens.
  PathAction tick(DateTime now, {required bool transferring}) {
    if (path == LinkPath.usb && !cableUp) {
      return _switch(LinkPath.wifi, now, PathReason.cableLost);
    }
    // On the cable, still no measurement long after the trial window (e.g. the reconnect through the cable never
    // completed): give the cable up even when nothing is "transferring", otherwise the session waits forever.
    if (path == LinkPath.usb && cableMbps == null && _switchedAt != null &&
        now.difference(_switchedAt!) >= settle + trial + noDataGrace && meter.rate(now) == null) {
      cableRejected = true;
      return _switch(LinkPath.wifi, now, PathReason.cableNoData);
    }
    if (!transferring) return PathAction.none;
    if (path == LinkPath.wifi) {
      if (!cableUp || cableRejected) return PathAction.none;
      wifiMbps = meter.rate(now);
      return _switch(LinkPath.usb, now, wifiMbps == null ? PathReason.wifiUnmeasured : PathReason.cableConnected);
    }
    // On the cable: measure once, after it settled.
    final since = _switchedAt == null ? Duration.zero : now.difference(_switchedAt!);
    if (cableMbps != null || since < settle + trial) return PathAction.none;
    final measured = meter.rate(now);
    if (measured == null) return PathAction.none; // stalled (paused peer, big fsync): wait for real data
    cableMbps = measured;
    if (measured < noDataMbps) {
      cableRejected = true;
      return _switch(LinkPath.wifi, now, PathReason.cableNoData);
    }
    final w = wifiMbps;
    if (w != null && measured < w * slowerRatio) {
      cableRejected = true;
      return _switch(LinkPath.wifi, now, PathReason.cableSlower);
    }
    reason = PathReason.cableFaster;
    return PathAction.none;
  }

  PathAction _switch(LinkPath to, DateTime now, PathReason why) {
    path = to;
    reason = why;
    _switchedAt = now;
    if (to == LinkPath.usb) cableMbps = null;
    meter.reset();
    return to == LinkPath.usb ? PathAction.toCable : PathAction.toWifi;
  }
}
