import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/notifications/library_sync_notifier.dart';
import 'package:navis/src/utils/notifications/notification_localizations.dart';

void main() {
  final l10n = resolveNotificationLocalizations('en');

  test(
    'sync failure notification keeps technical detail out of recovery copy',
    () {
      const state = LibrarySyncState(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.idle,
        errorMessage: 'HTTP 502 from a server at private.example/internal',
      );

      expect(
        librarySyncNotificationFailureTitle(l10n, state),
        'Library scan failed',
      );
      expect(
        librarySyncNotificationFailureBody(l10n, state),
        'The scan could not finish. Open Navis to try again.',
      );
      expect(
        librarySyncNotificationFailureBody(l10n, state),
        isNot(contains('HTTP')),
      );
    },
  );

  test('cancelled sync notification retains the stopped-scan explanation', () {
    const state = LibrarySyncState(
      status: LibrarySyncStatus.failed,
      stage: LibrarySyncStage.idle,
      errorMessage: 'User cancelled sync',
    );

    expect(
      librarySyncNotificationFailureTitle(l10n, state),
      'Library scan cancelled',
    );
    expect(
      librarySyncNotificationFailureBody(l10n, state),
      'The scan stopped before it finished. Open Navis to try again.',
    );
  });

  test('progress and completion copy come from localizations', () {
    expect(
      l10n.notificationLibraryScanProgressBody('Refreshing albums', 3, 10),
      'Refreshing albums • 3/10',
    );
    expect(
      l10n.notificationLibraryScanCompleteHydrated(1),
      'Updated metadata and hydrated 1 album.',
    );
    expect(
      l10n.notificationLibraryScanCompleteHydrated(4),
      'Updated metadata and hydrated 4 albums.',
    );
  });
}
