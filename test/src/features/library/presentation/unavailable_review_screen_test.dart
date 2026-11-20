import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
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
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const UnavailableReviewScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Missing Favorite'), findsOneWidget);
    expect(find.text('An Artist'), findsOneWidget);
    expect(find.text('Find Match'), findsOneWidget);
    expect(find.text('Keep for Later'), findsOneWidget);
    // No liked song row behind this entry, so there is nothing to un-like.
    expect(find.text('Remove from Liked'), findsNothing);

    await tester.tap(find.text('Keep for Later'));
    await tester.pumpAndSettle();

    final rows = await pendingRecoveryReviews(database, serverId);
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
      SongsTableCompanion.insert(id: 'song-new', title: 'Missing Favorite'),
    ]);
    // A live reference the preview must surface.
    await database
        .into(database.playlistsTable)
        .insert(PlaylistsTableCompanion.insert(id: 'pl-1', name: 'Favorites'));
    await database.libraryDao.upsertProvisionalSongs([
      SongsTableCompanion.insert(id: 'song-gone', title: 'Missing Favorite'),
    ]);
    await database.customStatement(
      'INSERT INTO playlist_songs (playlist_id, song_id, sort_order) '
      "VALUES ('pl-1', 'song-gone', 0);",
    );

    await _pumpScreen(tester, database, serverId);

    await tester.tap(find.text('Find Match'));
    await tester.pumpAndSettle();
    // The candidate sheet lists the matching canonical song.
    await tester.tap(find.text('Missing Favorite').last);
    await tester.pumpAndSettle();

    // The preview shows old and new metadata plus the playlist reference.
    expect(find.text('Relink Item'), findsOneWidget);
    expect(find.text('Selected Replacement'), findsOneWidget);
    expect(find.textContaining('Playlist entries: 1'), findsOneWidget);

    await tester.tap(find.text('Relink'));
    await tester.pumpAndSettle();

    // The remap recorded the alias and resolved the entry.
    final aliases = await database
        .customSelect(
          'SELECT old_id, new_id FROM entity_identity_aliases '
          "WHERE entity_type = 'song';",
        )
        .get();
    expect(aliases, hasLength(1));
    expect(aliases.single.read<String>('old_id'), 'song-gone');
    expect(aliases.single.read<String>('new_id'), 'song-new');
    final pending = await pendingRecoveryReviews(database, serverId);
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
      SongsTableCompanion.insert(id: 'song-new', title: 'Missing Favorite'),
    ]);

    final notices = AppNoticeController();
    await _pumpScreen(tester, database, serverId, notices: notices);

    await tester.tap(find.text('Find Match'));
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

    expect(notices.notice?.message, contains('no longer current'));
    // The stale replacement is rejected: the entry stays pending and no
    // alias was recorded.
    final pending = await pendingRecoveryReviews(database, serverId);
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

  testWidgets(
    'a failed remap shows the neutral relink error, not the stale message',
    (tester) async {
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
        SongsTableCompanion.insert(id: 'song-new', title: 'Missing Favorite'),
      ]);

      final notices = AppNoticeController();
      await _pumpScreen(tester, database, serverId, notices: notices);

      await tester.tap(find.text('Find Match'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Missing Favorite').last);
      await tester.pumpAndSettle();
      // The remap itself fails while the replacement is still current.
      await database.customStatement('DROP TABLE entity_identity_aliases;');
      await tester.tap(find.text('Relink'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(notices.notice?.message, 'Couldn’t relink this item. Try again.');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
    skip: !sqliteAvailable,
  );

  testWidgets(
    'an entry deleted while Find Match is open shows already resolved',
    (tester) async {
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
        SongsTableCompanion.insert(id: 'song-new', title: 'Missing Favorite'),
      ]);

      final notices = AppNoticeController();
      await _pumpScreen(tester, database, serverId, notices: notices);

      await tester.tap(find.text('Find Match'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Missing Favorite').last);
      await tester.pumpAndSettle();
      // A sync resolves (deletes) the row while the preview is open.
      await database.customStatement('DELETE FROM library_recovery_review');
      await tester.tap(find.text('Relink'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(notices.notice?.message, 'This entry was already resolved.');
      expect(tester.takeException(), isNull);
      final aliases = await database
          .customSelect('SELECT old_id FROM entity_identity_aliases;')
          .get();
      expect(aliases, isEmpty);

      // Let the notice's auto-dismiss timer finish.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
    skip: !sqliteAvailable,
  );

  group('grouped list and bulk actions', () {
    testWidgets('orders albums, artists, then songs under album headers', (
      tester,
    ) async {
      final (database, serverId) = await _seedServer();
      await _review(
        database,
        serverId,
        'album-gone',
        'Lost Album',
        type: 'album',
        subtitle: 'Some Band',
      );
      await _review(
        database,
        serverId,
        'artist-gone',
        'Lost Artist',
        type: 'artist',
      );
      await _song(database, 's1', 'First', album: 'Alpha Album', artist: 'Ann');
      await _song(
        database,
        's2',
        'Second',
        album: 'Alpha Album',
        artist: 'Ann',
      );
      await _song(database, 's3', 'Single', album: '', artist: 'Bo');
      await _review(database, serverId, 's3', 'Single');
      await _review(database, serverId, 's1', 'First');
      await _review(database, serverId, 's2', 'Second');

      await _pumpScreen(tester, database, serverId);

      double y(String text) => tester.getTopLeft(find.text(text)).dy;
      final order = [
        y('Albums'),
        y('Lost Album'),
        y('Artists'),
        y('Lost Artist'),
        y('Alpha Album'),
        y('First'),
        y('Second'),
        y('Other Songs'),
        y('Single'),
      ];
      expect(order, orderedEquals([...order]..sort()));
      expect(order.toSet(), hasLength(order.length));
      await _tearDown(tester);
    }, skip: !sqliteAvailable);

    testWidgets('Keep All marks only pending rows and the list empties', (
      tester,
    ) async {
      final (database, serverId) = await _seedServer();
      await _review(database, serverId, 'a', 'A');
      await _review(database, serverId, 'b', 'B', type: 'album');
      await _review(database, serverId, 'c', 'C');
      final c = (await pendingRecoveryReviews(
        database,
        serverId,
      )).firstWhere((r) => r.oldId == 'c');
      await database.librarySyncDao.setRecoveryReviewDisposition(
        id: c.id,
        disposition: 'removedFromLiked',
      );

      await _pumpScreen(tester, database, serverId);
      await tester.tap(find.text('Keep All'));
      await tester.pumpAndSettle();

      expect(await pendingRecoveryReviews(database, serverId), isEmpty);
      final all = await database
          .select(database.libraryRecoveryReviewTable)
          .get();
      expect(
        {for (final r in all) r.oldId: r.disposition},
        {'a': 'keptForLater', 'b': 'keptForLater', 'c': 'removedFromLiked'},
      );
      expect(
        find.text('No unavailable items are waiting for review.'),
        findsOneWidget,
      );
      await _tearDown(tester);
    }, skip: !sqliteAvailable);

    testWidgets('Remove from Liked cancel changes nothing', (tester) async {
      final (database, serverId) = await _seedServer();
      await _song(database, 'gone', 'Gone', liked: true, tombstoned: true);
      await _review(database, serverId, 'gone', 'Gone');

      await _pumpScreen(tester, database, serverId);
      await tester.tap(find.text('Remove from Liked'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await database.libraryDao.getSongStarred('gone'), isNotNull);
      expect(await pendingRecoveryReviews(database, serverId), hasLength(1));
      expect(await database.starSyncDao.getPendingActions(), isEmpty);
      await _tearDown(tester);
    }, skip: !sqliteAvailable);

    testWidgets('confirm on a tombstoned song unlikes locally only', (
      tester,
    ) async {
      final (database, serverId) = await _seedServer();
      await _song(database, 'gone', 'Gone', liked: true, tombstoned: true);
      // An earlier star that never reached the server.
      await database.starSyncDao.queueStarAction(
        itemId: 'gone',
        itemType: 'song',
        action: 'star',
      );
      await _review(database, serverId, 'gone', 'Gone');

      await _pumpScreen(tester, database, serverId);
      await tester.tap(find.text('Remove from Liked'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(await database.libraryDao.getSongStarred('gone'), isNull);
      expect(await database.starSyncDao.getPendingActions(), isEmpty);
      final all = await database
          .select(database.libraryRecoveryReviewTable)
          .get();
      expect(all.single.disposition, 'removedFromLiked');
      await _tearDown(tester);
    }, skip: !sqliteAvailable);

    testWidgets('confirm on a live song still queues the unstar', (
      tester,
    ) async {
      final (database, serverId) = await _seedServer();
      await _song(database, 'live', 'Live', liked: true);
      await _review(
        database,
        serverId,
        'live',
        'Live',
        reason: 'ambiguousMatch',
      );

      await _pumpScreen(tester, database, serverId);
      await tester.tap(find.text('Remove from Liked'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(await database.libraryDao.getSongStarred('live'), isNull);
      final queue = await database.starSyncDao.getPendingActions();
      expect(queue.map((q) => (q.itemId, q.action)), [('live', 'unstar')]);
      await _tearDown(tester);
    }, skip: !sqliteAvailable);

    testWidgets('an external row offers no Remove from Liked', (tester) async {
      final (database, serverId) = await _seedServer();
      await _song(database, 'ext-1', 'Remote', liked: true);
      await _song(database, 'flagged', 'Flagged', liked: true, external: true);
      await _review(database, serverId, 'ext-1', 'Remote');
      await _review(database, serverId, 'flagged', 'Flagged');

      await _pumpScreen(tester, database, serverId);

      expect(find.text('Remove from Liked'), findsNothing);
      expect(find.text('Remove All from Liked'), findsNothing);
      await _tearDown(tester);
    }, skip: !sqliteAvailable);

    testWidgets('bulk remove covers only starred song rows, one confirmation', (
      tester,
    ) async {
      final (database, serverId) = await _seedServer();
      await _song(database, 'dead', 'Dead', liked: true, tombstoned: true);
      await _song(database, 'live', 'Live', liked: true);
      await _song(database, 'plain', 'Plain', tombstoned: true);
      await _song(database, 'ext-9', 'Remote', liked: true);
      for (final id in ['dead', 'live', 'plain', 'ext-9']) {
        await _review(database, serverId, id, id);
      }
      await _review(database, serverId, 'alb', 'Album', type: 'album');

      await _pumpScreen(tester, database, serverId);
      await tester.tap(find.text('Remove All from Liked'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(await database.libraryDao.getSongStarred('dead'), isNull);
      expect(await database.libraryDao.getSongStarred('live'), isNull);
      expect(await database.libraryDao.getSongStarred('ext-9'), isNotNull);
      final queue = await database.starSyncDao.getPendingActions();
      expect(queue.map((q) => (q.itemId, q.action)), [('live', 'unstar')]);
      final all = await database
          .select(database.libraryRecoveryReviewTable)
          .get();
      expect(
        {for (final r in all) r.oldId: r.disposition},
        {
          'dead': 'removedFromLiked',
          'live': 'removedFromLiked',
          'plain': 'pending',
          'ext-9': 'pending',
          'alb': 'pending',
        },
      );
      await _tearDown(tester);
    }, skip: !sqliteAvailable);
  });
}

Future<(NavisDatabase, int)> _seedServer() async {
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
  return (database, serverId);
}

Future<void> _review(
  NavisDatabase database,
  int serverId,
  String oldId,
  String title, {
  String type = 'song',
  String? subtitle,
  String reason = 'missingFromCatalog',
}) => database.librarySyncDao.recordRecoveryReview(
  serverId: serverId,
  entityType: type,
  oldId: oldId,
  savedTitle: title,
  savedSubtitle: subtitle,
  reason: reason,
  evidenceGeneration: 3,
);

Future<void> _song(
  NavisDatabase database,
  String id,
  String title, {
  String? album,
  String? artist,
  bool liked = false,
  bool tombstoned = false,
  bool external = false,
}) async {
  await database.libraryDao.upsertSongs([
    SongsTableCompanion.insert(
      id: id,
      title: title,
      albumName: Value(album),
      artistName: Value(artist),
      starred: liked ? Value(DateTime(2026)) : const Value.absent(),
      isExternal: Value(external),
    ),
  ]);
  if (tombstoned) {
    await database.customStatement(
      'UPDATE songs SET server_deleted_at = 1769904000 '
      "WHERE id = '$id'",
    );
  }
}

Future<void> _tearDown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> _pumpScreen(
  WidgetTester tester,
  NavisDatabase database,
  int serverId, {
  AppNoticeController? notices,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 2400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
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
        notifier: notices ?? AppNoticeController(),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const UnavailableReviewScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
