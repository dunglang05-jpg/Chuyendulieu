import 'package:flutter_test/flutter_test.dart';
import 'package:phone_transfer_pro/core/domain/capabilities.dart';
import 'package:phone_transfer_pro/core/domain/categories.dart';
import 'package:phone_transfer_pro/core/domain/state_machine.dart';

Capabilities caps(String platform, Map<String, (bool, bool)> cats) => Capabilities(
      platform: platform,
      role: 'both',
      osVersion: 'test',
      appVersion: 'test',
      categories: [
        for (final e in cats.entries)
          CategoryCapability(e.key, canExport: e.value.$1, canImport: e.value.$2, status: SupportStatus.supported)
      ],
    );

void main() {
  test('plan is sender.export ∩ receiver.import for every direction', () {
    final android = caps('android', {'photos': (true, true), 'contacts': (true, true), 'audio': (true, true)});
    final ios = caps('ios', {'photos': (true, true), 'contacts': (true, true), 'audio': (false, true)});
    expect(migrationPlan(android, ios), {'photos', 'contacts', 'audio'}); // A -> i
    expect(migrationPlan(ios, android), {'photos', 'contacts'}); // i -> A: iOS cannot export Music library
    expect(migrationPlan(android, android), {'photos', 'contacts', 'audio'}); // A -> A
    expect(migrationPlan(ios, ios), {'photos', 'contacts'}); // i -> i
  });

  test('capabilities JSON carries no device name and round-trips', () {
    final c = caps('ios', {'photos': (true, true)});
    final j = c.toJson();
    expect(j.containsKey('name'), isFalse);
    expect(Capabilities.fromJson(j).categories.single.id, 'photos');
  });

  test('registry covers both platforms for every category', () {
    for (final c in categoryRegistry) {
      expect(c.forPlatform('android').note, isNotEmpty);
      expect(c.forPlatform('ios').note, isNotEmpty);
    }
  });

  test('state machine: happy path, illegal jump, resume from failed', () {
    final sm = MigrationStateMachine();
    for (final s in [
      MigrationState.discovering,
      MigrationState.pairing,
      MigrationState.authenticating,
      MigrationState.capabilityExchange,
      MigrationState.scanning,
      MigrationState.preview,
      MigrationState.preparing,
      MigrationState.transferring,
      MigrationState.verifying,
      MigrationState.importing,
      MigrationState.completed,
    ]) {
      sm.go(s);
    }
    expect(sm.state, MigrationState.completed);
    expect(() => sm.go(MigrationState.transferring), throwsA(isA<IllegalTransition>()));

    final sm2 = MigrationStateMachine();
    expect(() => sm2.go(MigrationState.transferring), throwsA(isA<IllegalTransition>()));
    sm2
      ..go(MigrationState.discovering)
      ..go(MigrationState.pairing)
      ..go(MigrationState.failed);
    expect(sm2.specFor(MigrationState.failed, MigrationState.pairing)!.recovery, Recovery.rescanQr);
    sm2.go(MigrationState.pairing);
  });

  test('every transition that can fail names a recovery', () {
    for (final t in transitionTable) {
      // A version mismatch has no in-app recovery (update the app); every other failure must offer one.
      if (t.errorKey != null && t.errorKey != 'err_version') {
        expect(t.recovery, isNot(Recovery.none), reason: '${t.from}->${t.to}');
      }
    }
  });
}
