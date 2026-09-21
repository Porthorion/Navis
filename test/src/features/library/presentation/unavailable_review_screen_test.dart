import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/presentation/unavailable_review_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_theme.dart';

import '../../../../helpers/test_database.dart';

void main() {
  testWidgets('review screen lists pending entries and applies dispositions', (
    tester,
  ) async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final serverId = await database
        .into(database.serverConfigTable)
        .insert(
          ServerConfigTableCompanion.insert(
            url: 'https://example.com',
            username: 'alice',
            apiVersion: '1.16.1',
          ),
        );
    await database.librarySyncDao.recordRecoveryReview(
      serverId: serverId,
      entityType: 'song',
      oldId: 'song-gone',
      savedTitle: 'Missing Favorite',
      savedSubtitle: 'An Artist',
      reason: 'missingFromCatalog',
      evidenceGeneration: 3,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          serverConfigStateProvider.overrideWithValue(
            AsyncData(
              ServerConfigModel(
                id: serverId,
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const UnavailableReviewScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Missing Favorite'), findsOneWidget);
    expect(find.text('An Artist'), findsOneWidget);
    expect(find.text('Find match'), findsOneWidget);
    expect(find.text('Keep for later'), findsOneWidget);
    expect(find.text('Remove from Liked'), findsOneWidget);

    await tester.tap(find.text('Keep for later'));
    await tester.pumpAndSettle();

    final rows = await database.librarySyncDao.getPendingRecoveryReview(
      serverId,
    );
    expect(rows, isEmpty);

    // Tear the provider tree down before the test binding checks timers.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, skip: !sqliteAvailable);
}
