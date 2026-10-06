import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/test_database.dart';

/// Answers `/search/artist` and `/artist/{id}/albums` from fixtures and
/// records every request.
class _FakeDeezer extends DeezerApiClient {
  new() : super(dio: Dio());

  final List<String> calls = <String>[];
  final List<int> albumLimits = <int>[];
  final Map<String, int> artistIds = <String, int>{};
  final Map<int, List<DeezerAlbum>> albums = <int, List<DeezerAlbum>>{};
  final Set<int> failingArtists = <int>{};

  /// The priority of every request, in order.
  final List<bool> background = <bool>[];

  @override
  Future<List<DeezerArtist>> searchArtists(
    String name, {
    int limit = 25,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    calls.add('search/artist:$name');
    this.background.add(background);
    final id = artistIds[name];
    return id == null
        ? const <DeezerArtist>[]
        : <DeezerArtist>[DeezerArtist(id: id, name: name)];
  }

  @override
  Future<List<DeezerAlbum>> getArtistAlbums(
    int artistId, {
    int limit = 100,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    calls.add('albums:$artistId');
    this.background.add(background);
    albumLimits.add(limit);
    if (failingArtists.contains(artistId)) {
      throw const DeezerApiException(code: 2, message: 'boom');
    }
    return albums[artistId] ?? const <DeezerAlbum>[];
  }
}

class _SyncState extends Notifier<LibrarySyncState> {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  // A test control, not a property.
  // ignore: use_setters_to_change_properties
  void set(LibrarySyncState value) => state = value;
}

final _syncState = NotifierProvider<_SyncState, LibrarySyncState>(
  _SyncState.new,
);

class _AccountScope extends Notifier<String?> {
  @override
  String? build() => 'first-account';
  set scope(String? value) {
    state = value;
  }
}

final _accountScope = NotifierProvider<_AccountScope, String?>(
  _AccountScope.new,
);

void main() {
  late Directory cacheRoot;
  late _FakeDeezer deezer;
  late NavisDatabase database;

  setUp(() {
    cacheRoot = Directory.systemTemp.createTempSync('home_new_releases_test_');
    deezer = _FakeDeezer();
    database = createTestDatabase();
  });

  tearDown(() async {
    await database.close();
    if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
  });

  Future<void> artist(String id, String name, {int plays = 1}) async {
    await database
        .into(database.artistsTable)
        .insert(ArtistsTableCompanion.insert(id: id, name: name));
    await database
        .into(database.songsTable)
        .insert(
          SongsTableCompanion.insert(
            id: '$id-song',
            title: 'Song',
            artistId: Value(id),
            playCount: Value(plays),
          ),
        );
  }

  Future<void> libraryAlbum(String id, String name, String artistId) => database
      .into(database.albumsTable)
      .insert(
        AlbumsTableCompanion.insert(
          id: id,
          name: name,
          artistId: Value(artistId),
        ),
      );

  ProviderContainer container({
    IntegrationPolicy policy = const IntegrationPolicy(),
    IntegrationCallRecorder? recorder,
    Duration startupDelay = Duration.zero,
    List<Override> extra = const <Override>[],
    Override? accountScope,
  }) {
    final root = cacheRoot;
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          integrationPolicyProvider.overrideWithValue(policy),
          accountScope ??
              integrationAccountScopeProvider.overrideWithValue(
                'fixture-account',
              ),
          integrationJsonCacheProvider.overrideWithValue(
            IntegrationJsonCache(readRootDirectory: () async => root),
          ),
          deezerApiClientProvider.overrideWithValue(deezer),
          homeDeezerStartupDelayProvider.overrideWithValue(startupDelay),
          homeDeezerSyncRunningProvider.overrideWith(
            (ref) => ref.watch(_syncState).isRunning,
          ),
          homeNewReleasesClockProvider.overrideWithValue(
            () => DateTime(2026, 10, 5),
          ),
          if (recorder != null)
            integrationCallRecorderProvider.overrideWithValue(recorder),
          ...extra,
        ],
      ),
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<List<HomeNewRelease>> read(ProviderContainer container) {
    // Riverpod pauses providers nobody listens to.
    final subscription = container.listen(homeNewReleasesProvider, (_, _) {});
    addTearDown(subscription.close);
    return container.read(homeNewReleasesProvider.future);
  }

  test('account changes rebuild results and signing out clears Home', () async {
    await artist('a', 'Artist');
    deezer.artistIds['Artist'] = 10;
    deezer.albums[10] = const [
      DeezerAlbum(id: 101, title: 'Release', releaseDate: '2026-10-02'),
    ];
    final c = container(
      accountScope: integrationAccountScopeProvider.overrideWith(
        (ref) => ref.watch(_accountScope),
      ),
    );
    expect(await read(c), hasLength(1));
    final firstCalls = deezer.calls.length;
    c.read(_accountScope.notifier).scope = 'second-account';
    expect(await read(c), hasLength(1));
    expect(deezer.calls.length, greaterThan(firstCalls));
    c.read(_accountScope.notifier).scope = null;
    expect(await read(c), isEmpty);
  });

  test('sync refresh replaces an empty completed Home result', () async {
    final c = container();
    expect(await read(c), isEmpty);
    await artist('a', 'Artist');
    deezer.artistIds['Artist'] = 10;
    deezer.albums[10] = const [
      DeezerAlbum(id: 101, title: 'Release', releaseDate: '2026-10-02'),
    ];
    c.read(refreshIntegrationLibraryResultsProvider)();
    expect(await read(c), hasLength(1));
  });

  test('asks Deezer nothing while the switch is off', () async {
    await artist('a', 'Artist A');
    for (final policy in <IntegrationPolicy>[
      const IntegrationPolicy(disabledKeys: <String>{'deezer.newReleases'}),
      const IntegrationPolicy(disabledKeys: <String>{'deezer'}),
      const IntegrationPolicy(masterEnabled: false),
      const IntegrationPolicy.denyAll(),
    ]) {
      expect(await read(container(policy: policy)), isEmpty);
    }
    expect(deezer.calls, isEmpty);
  });

  test('asks Deezer nothing when no artist has songs', () async {
    await database
        .into(database.artistsTable)
        .insert(ArtistsTableCompanion.insert(id: 'a', name: 'Never Played'));
    expect(await read(container()), isEmpty);
    expect(deezer.calls, isEmpty);
  });

  test('little play history is topped up with library artists', () async {
    await artist('played', 'Played Artist', plays: 1);
    // 35 artists never played: more songs ranks higher.
    for (var i = 0; i < 35; i++) {
      await artist('lib$i', 'Library $i', plays: 0);
      for (var extra = 0; extra < i; extra++) {
        await database
            .into(database.songsTable)
            .insert(
              SongsTableCompanion.insert(
                id: 'lib$i-extra$extra',
                title: 'Song',
                artistId: Value('lib$i'),
              ),
            );
      }
    }
    deezer.artistIds.addAll(<String, int>{'Played Artist': 1, 'Library 34': 2});
    deezer.albums[1] = const <DeezerAlbum>[
      DeezerAlbum(id: 11, title: 'Same Day A', releaseDate: '2026-10-02'),
    ];
    deezer.albums[2] = const <DeezerAlbum>[
      DeezerAlbum(id: 21, title: 'Same Day B', releaseDate: '2026-10-02'),
      DeezerAlbum(id: 22, title: 'Too Old', releaseDate: '2026-08-01'),
    ];
    final recorder = IntegrationCallRecorder();

    final releases = await read(container(recorder: recorder));

    final searched = deezer.calls
        .where((call) => call.startsWith('search/artist:'))
        .toList();
    expect(searched, hasLength(kNewReleasesCandidateArtists));
    expect(searched.first, 'search/artist:Played Artist');
    expect(searched[1], 'search/artist:Library 34');
    expect(searched, isNot(contains('search/artist:Library 4')));
    // The played artist ranks first on a tie; the window still applies.
    expect(releases.map((r) => r.album.id), <int>[11, 21]);
    final span = recorder.recentSpans().lastWhere(
      (span) => span.name == kHomeNewReleasesSpan,
    );
    expect(span.counts['artists'], kNewReleasesCandidateArtists);
  });

  test('lists recent releases of the top artists, newest first', () async {
    await artist('a', 'Artist A', plays: 9);
    await artist('b', 'Artist B', plays: 4);
    await artist('c', 'Unknown To Deezer', plays: 2);
    await libraryAlbum('lib-first', 'First Light', 'a');
    deezer.artistIds.addAll(<String, int>{'Artist A': 10, 'Artist B': 20});
    deezer.albums[10] = const <DeezerAlbum>[
      DeezerAlbum(
        id: 101,
        title: 'Encore',
        releaseDate: '2026-10-02',
        recordType: 'single',
      ),
      DeezerAlbum(
        id: 102,
        title: 'First Light',
        releaseDate: '2026-09-20',
        recordType: 'album',
      ),
      DeezerAlbum(
        id: 103,
        title: 'Old',
        releaseDate: '2025-01-01',
        recordType: 'album',
      ),
    ];
    deezer.albums[20] = const <DeezerAlbum>[
      DeezerAlbum(
        id: 201,
        title: 'Side B',
        releaseDate: '2026-10-04',
        recordType: 'ep',
      ),
    ];
    final recorder = IntegrationCallRecorder();

    final releases = await read(container(recorder: recorder));

    expect(releases.map((r) => r.album.title), <String>[
      'Side B',
      'Encore',
      'First Light',
    ]);
    expect(releases.map((r) => r.artistId), <String>['b', 'a', 'a']);
    expect(releases.last.libraryAlbumId, 'lib-first');
    expect(releases.first.libraryAlbumId, isNull);
    // Only the first few releases of each artist Deezer knows.
    expect(deezer.albumLimits, everyElement(5));
    expect(
      deezer.calls.where((call) => call.startsWith('albums:')).toSet(),
      <String>{'albums:10', 'albums:20'},
    );
    final span = recorder.recentSpans().lastWhere(
      (span) => span.name == kHomeNewReleasesSpan,
    );
    expect(span.counts, <String, int>{
      'artists': 3,
      'resolved': 2,
      'failed': 0,
      'releases': 3,
      'inLibrary': 1,
    });
  });

  test('asks Deezer in the background, after what the user opens', () async {
    await artist('a', 'Artist A');
    deezer.artistIds['Artist A'] = 10;
    deezer.albums[10] = const <DeezerAlbum>[
      DeezerAlbum(id: 101, title: 'Encore', releaseDate: '2026-10-02'),
    ];

    expect(await read(container()), hasLength(1));
    expect(deezer.calls, ['search/artist:Artist A', 'albums:10']);
    expect(deezer.background, [true, true]);
  });

  test('an artist whose request fails is skipped', () async {
    await artist('a', 'Artist A', plays: 9);
    await artist('b', 'Artist B', plays: 4);
    deezer.artistIds.addAll(<String, int>{'Artist A': 10, 'Artist B': 20});
    deezer.failingArtists.add(10);
    deezer.albums[20] = const <DeezerAlbum>[
      DeezerAlbum(id: 201, title: 'Side B', releaseDate: '2026-10-04'),
    ];
    final releases = await read(container());
    expect(releases.map((r) => r.album.id), <int>[201]);
  });

  test('cached releases are not fetched again', () async {
    await artist('a', 'Artist A');
    deezer.artistIds['Artist A'] = 10;
    deezer.albums[10] = const <DeezerAlbum>[
      DeezerAlbum(id: 101, title: 'Encore', releaseDate: '2026-10-02'),
    ];
    expect(await read(container()), hasLength(1));
    final requests = deezer.calls.length;
    expect(await read(container()), hasLength(1));
    expect(deezer.calls, hasLength(requests));
  });

  test('waits for a running library sync before asking Deezer', () async {
    await artist('a', 'Artist A');
    deezer.artistIds['Artist A'] = 10;
    final c = container();
    c
        .read(_syncState.notifier)
        .set(
          const LibrarySyncState(
            status: LibrarySyncStatus.running,
            stage: LibrarySyncStage.fetchingSongs,
          ),
        );
    final subscription = c.listen(homeNewReleasesProvider, (_, _) {});
    addTearDown(subscription.close);
    final result = c.read(homeNewReleasesProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(deezer.calls, isEmpty);
    c.read(_syncState.notifier).set(const LibrarySyncState.idle());
    expect(await result, isEmpty);
    expect(deezer.calls, contains('search/artist:Artist A'));
  });

  test('a sync that starts during the startup delay also goes first', () async {
    await artist('a', 'Artist A');
    deezer.artistIds['Artist A'] = 10;
    final c = container(startupDelay: const Duration(milliseconds: 200));
    final subscription = c.listen(homeNewReleasesProvider, (_, _) {});
    addTearDown(subscription.close);
    final result = c.read(homeNewReleasesProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    c
        .read(_syncState.notifier)
        .set(
          const LibrarySyncState(
            status: LibrarySyncStatus.running,
            stage: LibrarySyncStage.fetchingSongs,
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(deezer.calls, isEmpty);
    c.read(_syncState.notifier).set(const LibrarySyncState.idle());
    expect(await result, isEmpty);
    expect(deezer.calls, contains('search/artist:Artist A'));
  });
}
