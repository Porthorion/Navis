import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/notifications/library_sync_notifier.dart';

void main() {
  test(
    'sync failure notification keeps technical detail out of recovery copy',
    () {
      const state = LibrarySyncState(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.idle,
        errorMessage: 'HTTP 502 from a server at private.example/internal',
      );

      expect(librarySyncNotificationFailureTitle(state), 'Library scan failed');
      expect(
        librarySyncNotificationFailureBody(state),
        'The scan could not finish. Open Navis to try again.',
      );
      expect(
        librarySyncNotificationFailureBody(state),
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
      librarySyncNotificationFailureTitle(state),
      'Library scan cancelled',
    );
    expect(
      librarySyncNotificationFailureBody(state),
      'The scan stopped before it finished. Open Navis to try again.',
    );
  });
}
