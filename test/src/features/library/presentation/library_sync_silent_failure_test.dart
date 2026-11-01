import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';

import '../../../../helpers/test_theme.dart';

LibrarySyncState _failed(String category) => LibrarySyncState(
  status: LibrarySyncStatus.failed,
  stage: LibrarySyncStage.completed,
  failureCategory: category,
  errorMessage: category == 'databaseBusy' ? '' : 'Metadata sync failed.',
);

void main() {
  test('only a failed databaseBusy state is silent', () {
    expect(_failed('databaseBusy').isSilentFailure, isTrue);
    // Past the quick retries the coordinator reports an ordinary failure.
    expect(_failed('sync').isSilentFailure, isFalse);
    expect(
      const LibrarySyncState(
        status: LibrarySyncStatus.deferred,
        stage: LibrarySyncStage.completed,
        failureCategory: 'databaseBusy',
      ).isSilentFailure,
      isFalse,
    );
  });

  for (final (category, shown) in [('databaseBusy', false), ('sync', true)]) {
    testWidgets(
      'the sync banner is ${shown ? 'shown' : 'hidden'} for $category',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: LibrarySyncStatusBanner(
                syncState: _failed(category),
                onRetry: () async {},
              ),
            ),
          ),
        );

        expect(
          find.byKey(LibrarySyncStatusBanner.bannerKey),
          shown ? findsOneWidget : findsNothing,
        );
      },
    );
  }
}
