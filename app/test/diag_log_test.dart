import 'package:flutter_test/flutter_test.dart';
import 'package:phone_transfer_pro/app/diag_log.dart';

void main() {
  final at = DateTime.utc(2026, 1, 1);

  test('unknown keys are dropped', () {
    final line = DiagLog.format('scan', {'category': 'photos', 'name': 'IMG_0001.HEIC', 'path': 'DCIM/x'}, at: at);
    expect(line, '2026-01-01T00:00:00.000Z scan category=photos');
  });

  test('values that could carry personal data are redacted even under allowed keys', () {
    for (final bad in [
      'DCIM/Camera/IMG_0001.HEIC', // path
      'an@example.com', // e-mail
      '192.168.1.23', // IP
      '192.168.1.23:47321',
      'ptp://pair?d=abc', // QR / URI
      r'C:\Users\x', // windows path
      'x' * 49, // too long
    ]) {
      expect(DiagLog.format('e', {'status': bad}, at: at), endsWith('status=<redacted>'), reason: bad);
    }
  });

  test('ordinary diagnostic values pass', () {
    expect(DiagLog.format('probe', {'os': 'Android 14 (API 34)', 'model': 'samsung SM-S911B', 'free': 123, 'charging': true}, at: at),
        '2026-01-01T00:00:00.000Z probe os=Android 14 (API 34) model=samsung SM-S911B free=123 charging=true');
  });

  test('event names are sanitised too', () {
    expect(DiagLog.format('a/b', const {}, at: at), endsWith('<redacted>'));
  });
}
