import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/test_database.dart';

class _BenchmarkListenBrainzApiClient extends ListenBrainzApiClient {
  new({required this.playlist});

  final ListenBrainzPlaylist playlist;

  @override
  Future<List<ListenBrainzPlaylist>> getRecommendationPlaylists({
    required String userName,
    String? userToken,
  }) async {
    return [
      const ListenBrainzPlaylist(
        identifier: 'jams',
        title: 'Weekly Jams',
        sourcePatch: 'weekly-jams',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
    ];
  }

  @override
  Future<ListenBrainzPlaylist> getPlaylist(
    String playlistMbid, {
    bool fetchMetadata = true,
    String? userToken,
  }) async {
    return playlist;
  }
}

class _BenchmarkExternalScrobbleCredentialStore
    implements ExternalScrobbleCredentialStore {
  const new();

  @override
  Future<void> clearListenBrainzToken() async {}

  @override
  Future<String?> readListenBrainzToken() async => 'fake-token';

  @override
  Future<void> saveListenBrainzToken(String value) async {}
}

void main() {
  test(
    'ListenBrainz weekly playlist matching benchmark with 10,000 library songs',
    () async {
      final database = createTestDatabase();

      print('Populating database with 10,000 songs...');
      final songsToInsert = <SongsTableCompanion>[];
      for (var i = 0; i < 10000; i++) {
        songsToInsert.add(
          SongsTableCompanion.insert(
            id: 'song-$i',
            title: 'Song Title $i',
            artistName: Value('Artist Name $i'),
            albumName: Value('Album Name $i'),
            duration: const Value(200),
          ),
        );
      }
      await database.libraryDao.upsertSongs(songsToInsert);

      // Create 50 target tracks, most with mismatched names to trigger the fallback
      final targetTracks = <ListenBrainzPlaylistTrack>[];
      for (var i = 0; i < 50; i++) {
        targetTracks.add(
          ListenBrainzPlaylistTrack(
            title: 'Song Title $i slightly mismatched',
            creator: 'Artist Name $i',
            album: 'Album Name $i',
            durationMs: 200000,
          ),
        );
      }

      final playlist = ListenBrainzPlaylist(
        identifier: 'jams',
        title: 'Weekly Jams',
        sourcePatch: 'weekly-jams',
        tracks: targetTracks,
      );

      final fakeListenBrainz = _BenchmarkListenBrainzApiClient(
        playlist: playlist,
      );
      final fakeSubsonic = SubsonicApiClient(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'password',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            listenBrainzDiscoverStartupIdleDelayProvider.overrideWithValue(
              Duration.zero,
            ),
            listenBrainzDiscoverStartupSyncStateProvider.overrideWithValue(
              const LibrarySyncState.idle(),
            ),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _BenchmarkExternalScrobbleCredentialStore(),
            ),
            listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
            subsonicApiProvider.overrideWithValue(fakeSubsonic),
          ],
        ),
      );

      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      print('Starting matching resolution...');
      final stopwatch = Stopwatch()..start();
      final result = await container.read(listenBrainzDiscoverProvider.future);
      stopwatch.stop();

      print('Matching resolved in: ${stopwatch.elapsedMilliseconds} ms');
      expect(result, isNotEmpty);
    },
  );
}
