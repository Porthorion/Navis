import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';

const _chart = <ResolvedArtistTopTrack>[
  ResolvedArtistTopTrack(
    rank: 1,
    title: 'One',
    artist: 'A',
    resolvedSong: Song(id: 's1', title: 'One'),
  ),
  ResolvedArtistTopTrack(rank: 2, title: 'Two', artist: 'A'),
];

const _weekly = AsyncData<List<ListenBrainzDiscoverPlaylist>>(
  <ListenBrainzDiscoverPlaylist>[
    ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: 'jams',
        title: 'Weekly Jams',
        sourcePatch: 'weekly-jams',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
      recommendations: <ListenBrainzResolvedRecommendation>[],
    ),
  ],
);

void main() {
  ProviderContainer container({
    IntegrationPolicy policy = const IntegrationPolicy(),
    String? scope = 'account',
    Stream<List<ResolvedArtistTopTrack>>? trending,
    AsyncValue<List<PlaylistsTableData>> playlists =
        const AsyncData<List<PlaylistsTableData>>(<PlaylistsTableData>[
          PlaylistsTableData(id: 'server-playlist', name: 'Server Mix'),
        ]),
    bool withWeekly = true,
  }) {
    final c = ProviderContainer(
      overrides: <Override>[
        integrationPolicyProvider.overrideWithValue(policy),
        integrationAccountScopeProvider.overrideWithValue(scope),
        homeTrendingProvider.overrideWith(
          (ref) => trending ?? Stream.value(_chart),
        ),
        playlistListProvider.overrideWithValue(playlists),
        listenBrainzDiscoverStreamProvider.overrideWithValue(
          withWeekly ? _weekly : const AsyncLoading(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<List<PlaylistLibraryItem>> items(ProviderContainer c) async {
    final subscription = c.listen(playlistLibraryItemsProvider, (_, _) {});
    addTearDown(subscription.close);
    await Future<void>.delayed(Duration.zero);
    return c.read(playlistLibraryItemsProvider).requireValue;
  }

  test('Trending sits right under the weekly playlists', () async {
    final result = await items(container());
    expect(result.map((item) => item.id), <String>[
      listenBrainzWeeklyJamsVirtualPlaylistId,
      trendingVirtualPlaylistId,
      'server-playlist',
    ]);
    final trending = result[1];
    expect(trending.isVirtual, isTrue);
    expect(trending.isTrending, isTrue);
    expect(trending.trendingTracks, hasLength(2));
    expect(trending.songCount, 2);
    expect(trendingVirtualPlaylistId, NavService.trendingPlaylistId);
  });

  test(
    'Trending stays listed while its chart loads or comes back empty',
    () async {
      final loading = await items(
        container(trending: const Stream<List<ResolvedArtistTopTrack>>.empty()),
      );
      expect(loading.where((item) => item.isTrending), hasLength(1));
      expect(
        loading.singleWhere((item) => item.isTrending).trendingTracks,
        isNull,
      );

      final empty = await items(
        container(trending: Stream.value(const <ResolvedArtistTopTrack>[])),
      );
      expect(empty.where((item) => item.isTrending), hasLength(1));
    },
  );

  test('Trending is left out while its switch is off or signed out', () async {
    for (final c in <ProviderContainer>[
      container(
        policy: const IntegrationPolicy(
          disabledKeys: <String>{'deezer.trending'},
        ),
      ),
      container(policy: const IntegrationPolicy(masterEnabled: false)),
      container(scope: null),
    ]) {
      final subscription = c.listen(playlistLibraryItemsProvider, (_, _) {});
      addTearDown(subscription.close);
      expect(
        c
            .read(playlistLibraryItemsProvider)
            .requireValue
            .map((item) => item.id),
        <String>[listenBrainzWeeklyJamsVirtualPlaylistId, 'server-playlist'],
      );
    }
  });

  test('Trending stays listed while server playlists load or fail, without '
      'weekly playlists', () async {
    for (final playlists in <AsyncValue<List<PlaylistsTableData>>>[
      const AsyncLoading(),
      AsyncError(StateError('db'), StackTrace.empty),
    ]) {
      final result = await items(
        container(playlists: playlists, withWeekly: false),
      );
      expect(result.map((item) => item.id), <String>[
        trendingVirtualPlaylistId,
      ]);
    }
    final withWeekly = await items(container(playlists: const AsyncLoading()));
    expect(withWeekly.map((item) => item.id), <String>[
      listenBrainzWeeklyJamsVirtualPlaylistId,
      trendingVirtualPlaylistId,
    ]);
  });

  test(
    'weekly playlists stay listed when server playlist reads fail',
    () async {
      final result = await items(
        container(
          playlists: AsyncError(
            StateError('server read failed'),
            StackTrace.empty,
          ),
          policy: const IntegrationPolicy(disabledKeys: {'deezer.trending'}),
        ),
      );
      expect(result.map((item) => item.id), [
        listenBrainzWeeklyJamsVirtualPlaylistId,
      ]);
      expect(result.single.isVirtual, isTrue);
      expect(result.single.name, 'Weekly Jams');
    },
  );

  test('nothing virtual: loading and errors show as before', () {
    for (final (playlists, isError)
        in <(AsyncValue<List<PlaylistsTableData>>, bool)>[
          (const AsyncLoading(), false),
          (AsyncError(StateError('db'), StackTrace.empty), true),
        ]) {
      final c = container(
        playlists: playlists,
        withWeekly: false,
        policy: const IntegrationPolicy(masterEnabled: false),
      );
      final subscription = c.listen(playlistLibraryItemsProvider, (_, _) {});
      addTearDown(subscription.close);
      final value = c.read(playlistLibraryItemsProvider);
      expect(value.hasValue, isFalse);
      expect(value.hasError, isError);
    }
  });
}
