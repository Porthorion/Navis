import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/playlist.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_detail_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _Api extends Mock implements SubsonicApiClient {}

class _Queue extends QueueController {
  int? startIndex;
  List<String>? ids;
  @override
  List<String> build() => const [];
  @override
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
  }) async {
    this.startIndex = startIndex;
    ids = songs.map((song) => song.id).toList();
  }
}

const _duplicate = SongsTableData(
  id: 'duplicate',
  title: 'Repeated song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 3661,
  isExternal: false,
  isProvisional: false,
);
const _middle = SongsTableData(
  id: 'middle',
  title: 'Middle song',
  isExternal: false,
  isProvisional: false,
);

void main() {
  Future<ProviderContainer> render(
    WidgetTester tester,
    NavisDatabase database,
    _Api api, {
    bool filtered = false,
    bool mobile = false,
  }) async {
    final size = mobile ? const Size(360, 1200) : const Size(1000, 900);
    setAdaptiveTestViewport(tester, size);
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            subsonicApiProvider.overrideWithValue(api),
            queueProvider.overrideWith(_Queue.new),
            songStarredProvider.overrideWith((ref, id) => Stream.value(false)),
            downloadedOnlyFilterProvider.overrideWithBuild(
              (ref, _) => filtered,
            ),
            downloadedSongIdsProvider.overrideWithValue(
              const AsyncData({'duplicate'}),
            ),
            playlistByIdProvider('occurrences').overrideWith(
              (ref) => Stream.value(
                const PlaylistsTableData(
                  id: 'occurrences',
                  name: 'Occurrences',
                ),
              ),
            ),
            playlistSongsProvider('occurrences').overrideWith(
              (ref) => Stream.value(
                const [_duplicate, _middle, _duplicate],
              ),
            ),
            playlistDetailSyncProvider('occurrences')
                .overrideWith((ref) async {}),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: !mobile,
              viewportSize: size,
              safePadding: EdgeInsets.zero,
            ),
            child: const PlaylistDetailScreen(playlistId: 'occurrences'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(PlaylistDetailScreen)),
    );
  }

  testWidgets(
    'mobile filtered and reorderable duplicates keep controls beside tracks',
    (tester) async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final api = _Api();
      for (final filtered in [false, true]) {
        await render(tester, database, api, mobile: true, filtered: filtered);
        final rows = find.byType(AdaptiveTrackRow);
        expect(rows, findsNWidgets(filtered ? 2 : 3));
        for (final element in rows.evaluate()) {
          final row = element.widget as AdaptiveTrackRow;
          expect(row.actionExtent, filtered ? 96 : 144);
          final bounds = tester.getRect(find.byWidget(row));
          final menu = find.descendant(
            of: find.byWidget(row),
            matching: find.byIcon(Icons.more_vert),
          );
          expect(tester.getRect(menu).center.dy, bounds.center.dy);
          expect(bounds.height, lessThanOrEqualTo(72));
        }
        expect(find.text('#'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'filtered duplicate row plays and removes its original occurrence',
    (tester) async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final api = _Api();
      when(
        () => api.updatePlaylist(id: 'occurrences', songIndexesToRemove: [2]),
      ).thenAnswer(
        (_) async => const Playlist(id: 'occurrences', name: 'Occurrences'),
      );
      final container = await render(tester, database, api, filtered: true);
      expect(find.byType(AdaptiveTrackRow), findsNWidgets(2));
      expect(find.text('1:01:01'), findsNWidgets(2));
      await tester.tap(find.text('Repeated song').last);
      await tester.pump(const Duration(milliseconds: 1));
      final queue = container.read(queueProvider.notifier) as _Queue;
      expect(queue.ids, ['duplicate', 'duplicate']);
      expect(queue.startIndex, 1);
      await tester.tap(
        find.byKey(const ValueKey('playlist-song-menu-duplicate')).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      verify(
        () => api.updatePlaylist(id: 'occurrences', songIndexesToRemove: [2]),
      ).called(1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'reorderable duplicate rows keep unique occurrence keys and order',
    (tester) async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final api = _Api();
      when(
        () => api.replacePlaylistSongs(
          playlistId: 'occurrences',
          songIds: ['middle', 'duplicate', 'duplicate'],
        ),
      ).thenAnswer((_) async {});
      await render(tester, database, api);
      expect(
        find.byKey(const ValueKey('occurrences-duplicate-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('occurrences-duplicate-2')),
        findsOneWidget,
      );
      tester
          .widget<SliverReorderableList>(find.byType(SliverReorderableList))
          // This regression drives the existing production callback contract.
          // ignore: deprecated_member_use
          .onReorder!(0, 3);
      await tester.pumpAndSettle();
      verify(
        () => api.replacePlaylistSongs(
          playlistId: 'occurrences',
          songIds: ['middle', 'duplicate', 'duplicate'],
        ),
      ).called(1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
