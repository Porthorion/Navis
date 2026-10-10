import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/notifications/notification_localizations.dart';

void main() {
  test('download failure notifications use safe generic copy', () {
    final l10n = resolveNotificationLocalizations('en');
    expect(l10n.notificationDownloadFailedTitle, 'Download failed');
    expect(l10n.notificationDownloadFailedTitle, isNot(contains(':')));
  });

  test('download notification text comes from localizations', () {
    final l10n = resolveNotificationLocalizations('en');
    expect(l10n.notificationDownloadCompleteTitle('Song'), 'Downloaded: Song');
    expect(l10n.notificationDownloadProgressMultiple(3), 'Downloading 3 songs');
    expect(l10n.notificationDownloadProgressPercent(42), '42%');
  });

  test('unsupported locales fall back to English', () {
    final l10n = resolveNotificationLocalizations('xx');
    expect(l10n.localeName, 'en');
  });
}
