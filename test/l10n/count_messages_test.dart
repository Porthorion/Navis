import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  test('counts read naturally for one and many', () {
    expect(
      l10n.syncSettingsRemainingVerification(1),
      '1 artist remains to verify',
    );
    expect(
      l10n.syncSettingsRemainingVerification(2),
      '2 artists remain to verify',
    );
    expect(l10n.syncSettingsIntervalHours(1), 'Every hour');
    expect(l10n.syncSettingsIntervalHours(6), 'Every 6 hours');
    expect(l10n.syncSettingsLastRunValue(1, '2.0 KB'), '1 request • 2.0 KB');
    expect(
      l10n.syncSettingsCatalogPromotionRemovalSummary(0, 1, 230),
      'The last library update removed 0 artists, 1 album and 230 songs.',
    );
  });

  test('large counts are grouped', () {
    expect(
      l10n.syncSettingsRepairDeletionConfirmationPending(63733),
      startsWith('63,733 items the server no longer has'),
    );
  });

  test('no count message falls back to "(s)"', () {
    expect(<String>[
      l10n.syncSettingsPendingWorkValue(3),
      l10n.syncSettingsPendingWork(3),
      l10n.syncSettingsCarriedForward(3),
      l10n.syncSettingsUsage(3, '1 KB'),
      l10n.syncSettingsRepairDeletionConfirmationBody(3),
      l10n.syncSettingsStarredReconciliationRemovalSummary(1, 2, 3),
      l10n.serverSettingsCapabilitiesCount(3),
      l10n.cacheSettingsPrecacheSuccess(3),
    ], everyElement(isNot(contains('(s)'))));
  });
}
