import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/domain/download_failure_message.dart';
import 'package:navis/src/utils/notifications/notification_localizations.dart';

void main() {
  test('download failure notifications use safe generic copy', () {
    final l10n = resolveNotificationLocalizations('en');
    expect(l10n.notificationDownloadFailedTitle, 'Download failed');
    expect(
      l10n.notificationDownloadHeldTitle,
      'Downloads waiting for storage or access',
    );
    expect(l10n.notificationDownloadFailedTitle, isNot(contains(':')));
  });

  test('download notification text comes from localizations', () {
    final l10n = resolveNotificationLocalizations('en');
    expect(l10n.notificationDownloadCompleteTitle('Song'), 'Downloaded: Song');
    expect(l10n.notificationDownloadProgressMultiple(3), 'Downloading 3 songs');
    expect(l10n.notificationDownloadProgressPercent(42), '42%');
  });

  test('every persisted reason has localized notification copy', () {
    final l10n = resolveNotificationLocalizations('en');
    for (final reason in DownloadFailureReason.values) {
      final message = downloadFailureMessage(l10n, reason);
      expect(message, isNotEmpty);
      expect(message, isNot(contains('https://')));
    }
    expect(
      downloadFailureMessage(l10n, DownloadFailureReason.truncated),
      'The download was cut short. Try again.',
    );
  });

  test('unsupported locales fall back to English', () {
    final l10n = resolveNotificationLocalizations('xx');
    expect(l10n.localeName, 'en');
  });
}
