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

  test('library, playback and settings counts read naturally', () {
    expect(l10n.artistDetailAlbumCount(1), '1 album');
    expect(l10n.artistDetailAlbumCount(12), '12 albums');
    expect(l10n.searchAlbumCount(1), '1 album');
    expect(l10n.albumDetailMeta('Artist', 2024, 1), 'Artist • 2024 • 1 track');
    expect(
      l10n.albumDetailMeta('Artist', 2024, 14),
      'Artist • 2024 • 14 tracks',
    );
    expect(l10n.audioMuseMixGenerated(1), 'AI Mix created — 1 track queued.');
    expect(l10n.smartQueueStarted(25), '25 tracks queued via Smart Queue.');
    expect(l10n.eqFilterCount(1), '1 filter');
    expect(l10n.eqFilterCount(10), '10 filters');
    expect(l10n.syncSettingsIntervalMinutes(1), 'Every minute');
    expect(l10n.syncSettingsIntervalMinutes(30), 'Every 30 minutes');
    expect(
      l10n.syncSettingsIdentitySummary(1, 2),
      '1 cached song canonicalized; 2 ambiguous matches retained',
    );
    expect(
      l10n.librarySyncScanningSongIndex(1),
      'Metadata ready. Scanning song index (1 song found)',
    );
    expect(l10n.weeklyPlaylistMatchSuccess(1, 1), 'Matched 1 of 1 track');
    expect(l10n.cacheSettingsCoverArtMaxValue(1), '1 image');
  });

  test('large counts are grouped', () {
    expect(
      l10n.libraryAlbumsPagingProgress(1200, 4500),
      'Loaded 1,200 of 4,500 albums',
    );
    expect(l10n.artistPlaybackProgress(3, 1000), 'Loaded 3 of 1,000 albums');
    expect(
      l10n.librarySyncScanningSongIndex(57364),
      'Metadata ready. Scanning song index (57,364 songs found)',
    );
    expect(
      l10n.weeklyPlaylistMatchSuccess(1500, 2000),
      'Matched 1,500 of 2,000 tracks',
    );
    expect(l10n.cacheSettingsCoverArtMaxValue(10000), '10,000 images');
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
