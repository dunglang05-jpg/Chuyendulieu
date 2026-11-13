// Category "apps" (APK files + system install dialog, Android → Android). The Kotlin side needs real phones;
// this checks the shared model: it exists, is Android-only, and never reaches an iPhone or an older app.
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_transfer_pro/core/domain/capabilities.dart';
import 'package:phone_transfer_pro/core/domain/categories.dart';
import 'package:phone_transfer_pro/core/protocol/constants.dart';

Capabilities _caps(String platform, String role, List<String> ids) => Capabilities(
      platform: platform,
      role: role,
      osVersion: 'x',
      appVersion: 'test',
      categories: [
        for (final id in ids) CategoryCapability(id, canExport: true, canImport: true, status: SupportStatus.supported)
      ],
    );

void main() {
  test('apps is a known category, Android-only, install through the system dialog', () {
    expect(categoryIds, contains('apps'));
    final info = categoryRegistry.firstWhere((c) => c.id == 'apps');
    expect(info.forPlatform('android').import, SupportStatus.officialFlow);
    expect(info.forPlatform('ios').export, SupportStatus.unsupported);
    expect(info.forPlatform('ios').import, SupportStatus.unsupported);
  });

  test('plan includes apps only when the receiver also offers it', () {
    final sender = _caps('android', 'sender', ['photos', 'apps']);
    expect(migrationPlan(sender, _caps('android', 'receiver', ['photos', 'apps'])), contains('apps'));
    // iPhone receiver (or an older app without the category): not in the plan.
    expect(migrationPlan(sender, _caps('ios', 'receiver', ['photos'])), isNot(contains('apps')));
  });
}
