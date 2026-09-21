import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
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

  testWidgets('relink preview shows references and apply remaps the identity', (
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
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: 'song-new',
        title: 'Missing Favorite',
      ),
    ]);
    // A live reference the preview must surface.
    await database
        .into(database.playlistsTable)
        .insert(
          PlaylistsTableCompanion.insert(id: 'pl-1', name: 'Favorites'),
        );
    await database.libraryDao.upsertProvisionalSongs([
      SongsTableCompanion.insert(id: 'song-gone', title: 'Missing Favorite'),
    ]);
    await database.customStatement(
      "INSERT INTO playlist_songs (playlist_id, song_id, sort_order) "
      "VALUES ('pl-1', 'song-gone', 0);",
    );

    await _pumpScreen(tester, database, serverId);

    await tester.tap(find.text('Find match'));
    await tester.pumpAndSettle();
    // The candidate sheet lists the matching canonical song.
    await tester.tap(find.text('Missing Favorite').last);
    await tester.pumpAndSettle();

    // The preview shows old and new metadata plus the playlist reference.
    expect(find.text('Relink item'), findsOneWidget);
    expect(find.text('Selected replacement'), findsOneWidget);
    expect(find.textContaining('Playlist entries: 1'), findsOneWidget);

    await tester.tap(find.text('Relink'));
    await tester.pumpAndSettle();

    // The remap recorded the alias and resolved the entry.
    final aliases = await database
        .customSelect(
          "SELECT old_id, new_id FROM entity_identity_aliases "
          "WHERE entity_type = 'song';",
        )
        .get();
    expect(aliases, hasLength(1));
    expect(aliases.single.read<String>('old_id'), 'song-gone');
    expect(aliases.single.read<String>('new_id'), 'song-new');
    final pending = await database.librarySyncDao.getPendingRecoveryReview(
      serverId,
    );
    expect(pending, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, skip: !sqliteAvailable);

  testWidgets('a stale replacement is rejected at apply time', (tester) async {
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
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: 'song-new',
        title: 'Missing Favorite',
      ),
    ]);

    await _pumpScreen(tester, database, serverId);

    await tester.tap(find.text('Find match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Missing Favorite').last);
    await tester.pumpAndSettle();
    // The replacement disappears while the preview is open.
    await (database.delete(
      database.songsTable,
    )..where((t) => t.id.equals('song-new'))).go();
    await tester.tap(find.text('Relink'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // The stale replacement is rejected: the entry stays pending and no
    // alias was recorded.
    final pending = await database.librarySyncDao.getPendingRecoveryReview(
      serverId,
    );
    expect(pending, hasLength(1));
    final aliases = await database
        .customSelect(
          "SELECT old_id FROM entity_identity_aliases WHERE entity_type = 'song';",
        )
        .get();
    expect(aliases, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, skip: !sqliteAvailable);
}

Future<void> _pumpScreen(
  WidgetTester tester,
  NavisDatabase database,
  int serverId,
) async {
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
      child: AppNoticeScope(
        notifier: AppNoticeController(),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const UnavailableReviewScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
