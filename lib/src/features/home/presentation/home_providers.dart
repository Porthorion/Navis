import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:navis/l10n/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/data/local_track_matcher.dart';
import 'package:navis/src/features/library/data/provisional_search_songs.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/features/library/data/song_identity_cache_epoch.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/song_id_utils.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';

enum HomeRandomShowcaseSource { likedDiscovery, serverRandom, localFallback }

/// An item of the You Might Like hero: an album, or a virtual playlist
/// ([HomeRandomShowcasePlaylist]). Widgets switch over it exhaustively.
sealed class HomeRandomShowcaseItem {
  const new();

  String get stableId;
}

final class HomeRandomShowcaseAlbum extends HomeRandomShowcaseItem {
  const new({
    required this.id,
    required this.name,
    required this.source,
    this.artist,
    this.coverArtId,
    this.coverArtRevision = 0,
    this.year,
    this.songCount,
    this.isExternal = false,
  });

  factory fromServer(Album album, {int coverArtRevision = 0}) {
    return HomeRandomShowcaseAlbum(
      id: album.id,
      name: album.name,
      artist: album.artist,
      coverArtId: album.coverArt,
      coverArtRevision: coverArtRevision,
      year: album.year,
      songCount: album.songCount,
      source: HomeRandomShowcaseSource.serverRandom,
      isExternal: isExternalCatalogSource(
        id: album.id,
        apiIsExternal: album.isExternal,
      ),
    );
  }

  factory fromLocal(AlbumsTableData album) {
    return HomeRandomShowcaseAlbum(
      id: album.id,
      name: album.name,
      artist: album.artistName,
      coverArtId: album.coverArt,
      coverArtRevision: album.coverArtRevision ?? 0,
      year: album.year,
      songCount: album.songCount,
      source: HomeRandomShowcaseSource.localFallback,
      isExternal: album.isExternal,
    );
  }

  factory fromLocalDiscovery(AlbumsTableData album) {
    return HomeRandomShowcaseAlbum(
      id: album.id,
      name: album.name,
      artist: album.artistName,
      coverArtId: album.coverArt,
      coverArtRevision: album.coverArtRevision ?? 0,
      year: album.year,
      songCount: album.songCount,
      source: HomeRandomShowcaseSource.likedDiscovery,
      isExternal: album.isExternal,
    );
  }

  factory fromSimilarSong(Song song) {
    final albumId = song.albumId?.trim();
    final albumName = song.album?.trim();
    return HomeRandomShowcaseAlbum(
      id: albumId ?? song.id,
      name: (albumName != null && albumName.isNotEmpty)
          ? albumName
          : song.title,
      artist: song.artist,
      coverArtId: song.coverArt,
      year: song.year,
      source: HomeRandomShowcaseSource.likedDiscovery,
      isExternal: isExternalCatalogSource(
        id: song.id,
        apiIsExternal: song.isExternal,
      ),
    );
  }

  final String id;
  final String name;
  final String? artist;
  final String? coverArtId;
  final int coverArtRevision;
  final int? year;
  final int? songCount;
  final HomeRandomShowcaseSource source;
  final bool isExternal;

  @override
  String get stableId => 'album:$id';
}

/// A virtual playlist in the hero: a weekly ListenBrainz playlist or
/// Trending Now. They share one look: a mosaic of their songs' covers, a
/// title, an availability line and a numbered song list.
sealed class HomeRandomShowcasePlaylist extends HomeRandomShowcaseItem {
  const new();

  /// True while the playlist is still being fetched.
  bool get isLoading;

  /// The cover art of the playlist's songs, in order, for the mosaic and the
  /// hero's colour wash.
  Iterable<String> get coverArtIds;

  String localizedTitle(AppLocalizations l10n);
}

final class HomeRandomShowcaseListenBrainz extends HomeRandomShowcasePlaylist {
  factory({required ListenBrainzDiscoverPlaylist playlist}) {
    return HomeRandomShowcaseListenBrainz._(
      playlist: playlist,
      sourcePatch: playlist.playlist.sourcePatch,
      displayTitle: playlist.displayTitle,
      isLoading: playlist.recommendations.isEmpty && !playlist.matchingComplete,
    );
  }

  const new loading({required this.sourcePatch, required this.displayTitle})
    : playlist = null,
      isLoading = true;

  const new _({
    required this.playlist,
    required this.sourcePatch,
    required this.displayTitle,
    required this.isLoading,
  });

  final ListenBrainzDiscoverPlaylist? playlist;
  final String? sourcePatch;
  final String displayTitle;
  @override
  final bool isLoading;

  @override
  Iterable<String> get coverArtIds => <String>[
    for (final recommendation
        in playlist?.recommendations ??
            const <ListenBrainzResolvedRecommendation>[])
      if (recommendation.song?.coverArt ?? recommendation.tableSong?.coverArt
          case final cover? when cover.trim().isNotEmpty)
        cover,
  ];

  @override
  String localizedTitle(AppLocalizations l10n) => localizedWeeklyPlaylistTitle(
    l10n,
    sourcePatch: sourcePatch,
    fallback: displayTitle,
  );

  @override
  String get stableId {
    final source = sourcePatch?.trim();
    if (source != null && source.isNotEmpty) {
      return 'listenbrainz:$source';
    }
    return 'listenbrainz:${playlist!.playlist.identifier}';
  }
}

/// Trending Now: every Deezer chart song in chart order, each ranked by its
/// chart position, playable or not (see `homeTrendingProvider`).
final class HomeRandomShowcaseTrending extends HomeRandomShowcasePlaylist {
  /// [entries] and [songs] keep only the [tracks] with a resolved song and
  /// share one index.
  factory({required List<ResolvedArtistTopTrack> tracks}) {
    final entries = <({int rank, Song song})>[
      for (final track in tracks)
        if (track.resolvedSong case final song?) (rank: track.rank, song: song),
    ];
    return HomeRandomShowcaseTrending._(
      tracks: List<ResolvedArtistTopTrack>.unmodifiable(tracks),
      entries: List<({int rank, Song song})>.unmodifiable(entries),
    );
  }

  const new _({required this.tracks, required this.entries});

  /// Builds the hero item when at least [kTrendingMinimumPlayable] chart
  /// songs are playable, else null.
  static HomeRandomShowcaseTrending? forHero(
    List<ResolvedArtistTopTrack> tracks,
  ) {
    final playable = tracks.where((track) => track.resolvedSong != null);
    return playable.length < kTrendingMinimumPlayable
        ? null
        : HomeRandomShowcaseTrending(tracks: tracks);
  }

  /// Every chart song in chart order, with its song when one was found.
  final List<ResolvedArtistTopTrack> tracks;

  /// Each playable song with its chart position, in chart order.
  final List<({int rank, Song song})> entries;

  /// The songs to queue, in chart order.
  List<Song> get songs =>
      entries.map((entry) => entry.song).toList(growable: false);

  /// Whether the server is still being searched for some songs.
  bool get isMatching => tracks.any((track) => track.isMatching);

  @override
  bool get isLoading => false;

  @override
  Iterable<String> get coverArtIds => <String>[
    for (final entry in entries)
      if (entry.song.coverArt case final cover? when cover.trim().isNotEmpty)
        cover,
  ];

  @override
  String localizedTitle(AppLocalizations l10n) => l10n.homeTrendingTitle;

  @override
  String get stableId => 'trending:deezer';
}

const int _homeRandomShowcaseLimit = 12;
const int _homeRandomShowcaseMinSongCount = 3;
const int _homeRandomDiscoverySeedCount = 3;
const int _homeRandomDiscoveryMinLikedSongs = 5;
const int _homeRandomDiscoverySongCountPerSeed = 20;
const int _homeRandomDiscoveryMinResults = 6;
const Duration _homeRandomDiscoverySimilarSongTimeout = Duration(
  milliseconds: 1200,
);
const int _listenBrainzDiscoverTrackPreviewLimit = 35;
const int _listenBrainzDiscoverSearchSongCount = 8;
const int _listenBrainzDiscoverPlaylistDetailParallelism = 2;
const int _listenBrainzDiscoverSearchParallelism = 6;
const int _listenBrainzDiscoverAutomaticSearchParallelism = 2;
const int _listenBrainzDiscoverSearchEmitBatchSize = 6;
const int _listenBrainzDiscoverLocalMatchYieldBatchSize = 4;
const Duration _listenBrainzDiscoverDefaultStartupIdleDelay = Duration(
  minutes: 2,
);
const Duration _listenBrainzDiscoverStartupIdlePollInterval = Duration(
  milliseconds: 50,
);
const List<String> _listenBrainzShowcaseSourcePatches = <String>[
  'weekly-exploration',
  'weekly-jams',
];

List<ListenBrainzDiscoverPlaylist>? _listenBrainzDiscoverSessionCache;
List<ListenBrainzDiscoverPlaylist>? _listenBrainzDiscoverLastVisible;
int? _listenBrainzDiscoverSessionCacheEpoch;
String? _listenBrainzDiscoverSessionCacheKey;
bool _listenBrainzForceRematchOnNextRefresh = false;
bool _listenBrainzSkipStartupIdleOnce = false;
final Map<String, ListenBrainzResolvedRecommendation>
_listenBrainzDiscoverMatchCache =
    <String, ListenBrainzResolvedRecommendation>{};
_ListenBrainzLocalCandidateSnapshot? _listenBrainzLocalCandidateCache;
String? _listenBrainzLocalCandidateCacheFingerprint;
int? _listenBrainzMatchCacheIdentityEpoch;

class _BoundedAsyncQueue {
  new(this.maxConcurrent)
    : assert(maxConcurrent > 0, 'maxConcurrent must be positive');

  final int maxConcurrent;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  int _active = 0;

  Future<T> run<T>(Future<T> Function() operation) async {
    if (_active >= maxConcurrent) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await operation();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      }
    }
  }
}

/// Drops what the Home hero and Library playlists read of weekly discovery,
/// so a closed integration gate removes the virtual playlists at once. The
/// session key is reset too, so reopening the gate reloads rather than
/// resuming a stale session.
void _clearListenBrainzDiscoverVisibleState() {
  _listenBrainzDiscoverSessionCache = null;
  _listenBrainzDiscoverLastVisible = null;
  _listenBrainzDiscoverSessionCacheKey = null;
}

@visibleForTesting
void debugResetListenBrainzDiscoverSessionCacheForTests() {
  _listenBrainzDiscoverSessionCache = null;
  _listenBrainzDiscoverLastVisible = null;
  _listenBrainzDiscoverSessionCacheEpoch = null;
  _listenBrainzDiscoverSessionCacheKey = null;
  _listenBrainzDiscoverMatchCache.clear();
  _listenBrainzLocalCandidateCache = null;
  _listenBrainzLocalCandidateCacheFingerprint = null;
  _listenBrainzMatchCacheIdentityEpoch = null;
}

Future<void> _awaitListenBrainzStartupIdle(Ref ref, Duration delay) async {
  if (delay <= Duration.zero) {
    await Future<void>.delayed(Duration.zero);
    return;
  }
  final end = DateTime.now().add(delay);
  while (DateTime.now().isBefore(end)) {
    if (!ref.mounted) {
      return;
    }
    final remaining = end.difference(DateTime.now());
    await Future<void>.delayed(
      remaining < _listenBrainzDiscoverStartupIdlePollInterval
          ? remaining
          : _listenBrainzDiscoverStartupIdlePollInterval,
    );
  }
}

bool _listenBrainzDiscoverPlaylistsContentEqual(
  List<ListenBrainzDiscoverPlaylist> left,
  List<ListenBrainzDiscoverPlaylist> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    final leftPlaylist = left[index];
    final rightPlaylist = right[index];
    if (leftPlaylist.matchedCount != rightPlaylist.matchedCount ||
        leftPlaylist.totalCount != rightPlaylist.totalCount ||
        leftPlaylist.matchingComplete != rightPlaylist.matchingComplete) {
      return false;
    }
    if (_listenBrainzPlaylistVersionMarker(leftPlaylist.playlist) !=
        _listenBrainzPlaylistVersionMarker(rightPlaylist.playlist)) {
      return false;
    }
    // A recheck can swap a remote match for the server copy without changing
    // any count.
    final leftMatches = leftPlaylist.recommendations;
    final rightMatches = rightPlaylist.recommendations;
    for (var track = 0; track < leftMatches.length; track++) {
      if (leftMatches[track].song?.id != rightMatches[track].song?.id ||
          leftMatches[track].hasServerSong !=
              rightMatches[track].hasServerSong) {
        return false;
      }
    }
  }
  return true;
}

enum ListenBrainzRecommendationMatchStatus {
  pending,
  matched,
  unmatched,
  ambiguous,
}

class ListenBrainzResolvedRecommendation {
  const new({
    required this.track,
    required this.status,
    this.song,
    this.tableSong,
  });

  final ListenBrainzPlaylistTrack track;
  final ListenBrainzRecommendationMatchStatus status;
  final Song? song;
  final SongsTableData? tableSong;

  bool get isPlayable =>
      status == ListenBrainzRecommendationMatchStatus.matched && song != null;

  bool get hasServerSong =>
      status == ListenBrainzRecommendationMatchStatus.matched &&
      tableSong != null &&
      isServerAddressableSongId(tableSong!.id) &&
      tableSong!.serverDeletedAt == null;

  ListenBrainzResolvedRecommendation copyWith({
    ListenBrainzPlaylistTrack? track,
    ListenBrainzRecommendationMatchStatus? status,
    Song? song,
    SongsTableData? tableSong,
  }) {
    return ListenBrainzResolvedRecommendation(
      track: track ?? this.track,
      status: status ?? this.status,
      song: song ?? this.song,
      tableSong: tableSong ?? this.tableSong,
    );
  }
}

class ListenBrainzDiscoverPlaylist {
  const new({
    required this.playlist,
    required this.recommendations,
    this.matchingComplete = false,
    this.searchedAt,
  });

  final ListenBrainzPlaylist playlist;
  final List<ListenBrainzResolvedRecommendation> recommendations;
  final bool matchingComplete;

  /// When the server was last searched for this playlist's tracks (stored as
  /// the weekly cache row's `fetchedAt`); `null` when it never was. Remote and
  /// unmatched tracks are searched again once this is a day old.
  final DateTime? searchedAt;

  String get displayTitle => playlist.recommendationDisplayTitle;

  String localizedTitle(AppLocalizations l10n) => localizedWeeklyPlaylistTitle(
    l10n,
    sourcePatch: playlist.sourcePatch,
    fallback: displayTitle,
  );

  int get totalCount => recommendations.length;
  int get matchedCount => playableSongs.length;

  /// Every matched song, on the server or remote only, in playlist order.
  /// Play and Shuffle queue these; a remote song makes the server fetch it.
  List<Song> get playableSongs => recommendations
      .where((recommendation) => recommendation.isPlayable)
      .map((recommendation) => recommendation.song!)
      .toList(growable: false);

  ListenBrainzDiscoverPlaylist copyWith({
    ListenBrainzPlaylist? playlist,
    List<ListenBrainzResolvedRecommendation>? recommendations,
    bool? matchingComplete,
    DateTime? searchedAt,
  }) {
    return ListenBrainzDiscoverPlaylist(
      playlist: playlist ?? this.playlist,
      recommendations: recommendations ?? this.recommendations,
      matchingComplete: matchingComplete ?? this.matchingComplete,
      searchedAt: searchedAt ?? this.searchedAt,
    );
  }
}

/// The queue for playing the recommendation at [index] of [recommendations]
/// with Album Queue on: every playable song in playlist order, starting at
/// the tapped one. `null` when that recommendation cannot be played.
({List<Song> songs, int startIndex})? listenBrainzPlaybackFrom(
  List<ListenBrainzResolvedRecommendation> recommendations,
  int index,
) {
  if (index < 0 ||
      index >= recommendations.length ||
      !recommendations[index].isPlayable) {
    return null;
  }
  final songs = <Song>[];
  var startIndex = 0;
  for (var i = 0; i < recommendations.length; i++) {
    final recommendation = recommendations[i];
    if (!recommendation.isPlayable) continue;
    if (i == index) startIndex = songs.length;
    songs.add(recommendation.song!);
  }
  return (songs: songs, startIndex: startIndex);
}

/// A fixed Home showcase order for reproducible screenshots, set with
/// `--dart-define=NAVIS_DIAGNOSTICS_SHOWCASE_SEED=<n>`; unset in releases.
const _diagnosticsShowcaseSeed = int.fromEnvironment(
  'NAVIS_DIAGNOSTICS_SHOWCASE_SEED',
  defaultValue: -1,
);

class HomeRandomShowcaseShuffleSeedNotifier extends Notifier<int> {
  @override
  int build() => _diagnosticsShowcaseSeed >= 0
      ? _diagnosticsShowcaseSeed
      : Random().nextInt(1 << 31);

  void reshuffle() {
    state = Random().nextInt(1 << 31);
  }
}

final homeRandomShowcaseShuffleSeedProvider =
    NotifierProvider<HomeRandomShowcaseShuffleSeedNotifier, int>(
      HomeRandomShowcaseShuffleSeedNotifier.new,
    );

class ListenBrainzDiscoverRefreshEpochNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void refresh() {
    state++;
  }

  void refreshAfterLibrarySync() {
    _listenBrainzForceRematchOnNextRefresh = true;
    refresh();
  }

  void refreshAfterTokenValidation() {
    _listenBrainzSkipStartupIdleOnce = true;
    _listenBrainzDiscoverSessionCache = null;
    refresh();
  }

  void refreshFull() {
    _listenBrainzForceRematchOnNextRefresh = false;
    _listenBrainzDiscoverSessionCache = null;
    refresh();
  }
}

class ListenBrainzPlaylistRematchController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  bool isMatching(String sourcePatch) {
    final normalized = sourcePatch.trim();
    return normalized.isNotEmpty && state.contains(normalized);
  }

  Future<ListenBrainzDiscoverPlaylist> rematch(
    ListenBrainzDiscoverPlaylist playlist,
  ) async {
    final sourcePatch = playlist.playlist.sourcePatch?.trim() ?? '';
    if (sourcePatch.isEmpty) {
      throw StateError('ListenBrainz playlist is missing a source patch.');
    }
    if (state.contains(sourcePatch)) {
      throw StateError('ListenBrainz playlist is already matching.');
    }
    state = <String>{...state, sourcePatch};
    try {
      final matched = await _rematchListenBrainzPlaylist(ref, playlist);
      _listenBrainzDiscoverLastVisible = _replaceListenBrainzPlaylist(
        _listenBrainzDiscoverLastVisible,
        matched,
      );
      _listenBrainzDiscoverSessionCache = _replaceListenBrainzPlaylist(
        _listenBrainzDiscoverSessionCache,
        matched,
      );
      ref.invalidate(listenBrainzDiscoverStreamProvider);
      return matched;
    } finally {
      state = <String>{...state}..remove(sourcePatch);
    }
  }
}

final listenBrainzPlaylistRematchControllerProvider =
    NotifierProvider<ListenBrainzPlaylistRematchController, Set<String>>(
      ListenBrainzPlaylistRematchController.new,
    );

/// Rechecks weekly matches against the library after every library sync that
/// changed it, fully or partly, so a remote match switches to a newly synced
/// copy (see [ListenBrainzDiscoverRefreshEpochNotifier.refreshAfterLibrarySync]).
final listenBrainzLibrarySyncRefreshBridgeProvider = Provider<void>((ref) {
  ref.listen<LibrarySyncState>(librarySyncControllerProvider, (previous, next) {
    final finished =
        next.status == LibrarySyncStatus.succeeded ||
        next.status == LibrarySyncStatus.partial;
    if (finished && previous?.status != next.status) {
      final settings = ref.read(appSettingsProvider).asData?.value;
      if (settings?.listenBrainzTokenValid ?? false) {
        final epochAtSync = ref.read(listenBrainzDiscoverRefreshEpochProvider);
        // A sync transition may be flushed while Home is reading the derived
        // showcase provider. Defer the dependent invalidation until that
        // widget build has finished.
        unawaited(
          Future<void>(() {
            if (!ref.mounted) {
              return;
            }
            // Another refresh started meanwhile (Home pull-to-refresh starts
            // a full one right after its sync) and already sees the synced
            // library; replacing it would only repeat the work.
            if (ref.read(listenBrainzDiscoverRefreshEpochProvider) !=
                epochAtSync) {
              return;
            }
            ref
                .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
                .refreshAfterLibrarySync();
          }),
        );
      }
    }
  });
});

final listenBrainzDiscoverRefreshEpochProvider =
    NotifierProvider<ListenBrainzDiscoverRefreshEpochNotifier, int>(
      ListenBrainzDiscoverRefreshEpochNotifier.new,
    );

final listenBrainzDiscoverStartupIdleDelayProvider = Provider<Duration>(
  (_) => _listenBrainzDiscoverDefaultStartupIdleDelay,
);

final listenBrainzDiscoverStartupSyncStateProvider = Provider<LibrarySyncState>(
  (ref) {
    try {
      final syncTransition = ref.watch(
        librarySyncControllerProvider.select(
          (state) => (status: state.status, stage: state.stage),
        ),
      );
      return LibrarySyncState(
        status: syncTransition.status,
        stage: syncTransition.stage,
      );
    } on Object {
      return const LibrarySyncState.idle();
    }
  },
);

int _listenBrainzDiscoverStreamBuilds = 0;

/// How many times weekly discovery has (re)started in this process. Clone
/// diagnostics read it to prove which settings saves restart discovery.
int get listenBrainzDiscoverStreamBuildCount =>
    _listenBrainzDiscoverStreamBuilds;

final listenBrainzDiscoverStreamProvider =
    StreamProvider<List<ListenBrainzDiscoverPlaylist>>((ref) {
      _listenBrainzDiscoverStreamBuilds++;
      return _listenBrainzDiscoverStream(ref);
    });

Stream<List<ListenBrainzDiscoverPlaylist>> _listenBrainzDiscoverStream(
  Ref ref,
) async* {
  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);
  bool active() =>
      ref.mounted &&
      !cancelToken.isCancelled &&
      ref
          .read(integrationPolicyProvider)
          .isEnabled(IntegrationFeature.listenBrainzWeeklyPlaylists);
  final refreshEpoch = ref.watch(listenBrainzDiscoverRefreshEpochProvider);
  // Only the ListenBrainz identity restarts discovery; unrelated settings
  // saves (playback autosave, appearance, desktop volume) must not.
  final listenBrainzSettings = ref.watch(
    appSettingsProvider.select((async) {
      final settings = async.asData?.value ?? const AppSettingsModel.defaults();
      return (
        userName: settings.listenBrainzUserName,
        tokenValid: settings.listenBrainzTokenValid,
      );
    }),
  );
  final networkType = ref.watch(networkTypeProvider);
  final credentialStore = ref.read(externalScrobbleCredentialStoreProvider);
  final db = ref.read(navisDatabaseProvider);
  final cacheDao = db.cacheDao;
  final api = ref.read(subsonicApiProvider);
  final dao = db.libraryDao;
  final client = ref.read(listenBrainzApiClientProvider);
  final startupIdleDelay = ref.watch(
    listenBrainzDiscoverStartupIdleDelayProvider,
  );
  final useDiagnosticsCache = ref.watch(
    syncDiagnosticsOverridesProvider.select(
      (overrides) => overrides.cachedListenBrainzPresentation,
    ),
  );
  ref.watch(listenBrainzLibrarySyncRefreshBridgeProvider);
  // The weekly-playlists gate. It ignores credential verification on purpose:
  // the stream validates a stored token itself and then marks it valid, so
  // gating on verification here would stop that from ever happening. The
  // policy denies everything until settings have loaded.
  final weeklyPlaylistsEnabled = ref.watch(
    integrationPolicyProvider.select(
      (policy) =>
          policy.isEnabled(IntegrationFeature.listenBrainzWeeklyPlaylists),
    ),
  );
  if (!weeklyPlaylistsEnabled) {
    AppLogger.debug('ListenBrainz discover skipped: integration is off.');
    _clearListenBrainzDiscoverVisibleState();
    yield const <ListenBrainzDiscoverPlaylist>[];
    return;
  }

  String? token;
  try {
    token = (await credentialStore.readListenBrainzToken())?.trim();
  } on CredentialReadException {
    // Brief unavailability must not present the integration as tokenless.
    token = null;
  }
  final tokenText = token ?? '';
  if (!active()) return;
  if (tokenText.isEmpty) {
    if (useDiagnosticsCache) {
      final cachedUserName = await cacheDao
          .getLatestListenBrainzWeeklyCacheUserName();
      final cached = cachedUserName == null
          ? const <ListenBrainzDiscoverPlaylist>[]
          : await _loadListenBrainzWeeklyCache(
              cacheDao: cacheDao,
              libraryDao: dao,
              userName: cachedUserName,
            );
      AppLogger.debug(
        'ListenBrainz diagnostics cache presentation: count=${cached.length}.',
      );
      _listenBrainzDiscoverLastVisible = cached;
      yield cached;
      return;
    }
    AppLogger.debug(
      'ListenBrainz discover skipped: no stored ListenBrainz token.',
    );
    _listenBrainzDiscoverLastVisible = const <ListenBrainzDiscoverPlaylist>[];
    yield const <ListenBrainzDiscoverPlaylist>[];
    return;
  }

  var userName = listenBrainzSettings.userName?.trim();
  final tokenValid = listenBrainzSettings.tokenValid;
  if (!tokenValid || userName == null || userName.isEmpty) {
    if (networkType == NetworkType.offline) {
      AppLogger.debug(
        'ListenBrainz discover skipped: token flag stale and device offline.',
      );
      _listenBrainzDiscoverLastVisible = const <ListenBrainzDiscoverPlaylist>[];
      yield const <ListenBrainzDiscoverPlaylist>[];
      return;
    }
    try {
      final details = await client.validateTokenDetails(
        tokenText,
        cancelToken: cancelToken,
      );
      if (!active()) return;
      if (!details.valid) {
        AppLogger.debug(
          'ListenBrainz discover skipped: stored token failed validation.',
        );
        _listenBrainzDiscoverLastVisible =
            const <ListenBrainzDiscoverPlaylist>[];
        yield const <ListenBrainzDiscoverPlaylist>[];
        return;
      }
      userName = details.userName?.trim();
      if (userName == null || userName.isEmpty) {
        yield const <ListenBrainzDiscoverPlaylist>[];
        return;
      }
      await db.appSettingsDao.updateListenBrainzScrobblingState(
        tokenValid: true,
        userName: userName,
      );
    } on Object catch (error) {
      AppLogger.debug(
        'ListenBrainz discover skipped: token revalidation failed: $error',
      );
      _listenBrainzDiscoverLastVisible = const <ListenBrainzDiscoverPlaylist>[];
      yield const <ListenBrainzDiscoverPlaylist>[];
      return;
    }
  }

  if (userName.isEmpty) {
    AppLogger.debug(
      'ListenBrainz discover skipped: no validated ListenBrainz username.',
    );
    _listenBrainzDiscoverLastVisible = const <ListenBrainzDiscoverPlaylist>[];
    yield const <ListenBrainzDiscoverPlaylist>[];
    return;
  }

  final sessionKey = userName.toLowerCase();
  if (_listenBrainzDiscoverSessionCacheEpoch != refreshEpoch ||
      _listenBrainzDiscoverSessionCacheKey != sessionKey) {
    _listenBrainzDiscoverSessionCache = null;
    _listenBrainzDiscoverLastVisible = null;
    _listenBrainzDiscoverSessionCacheEpoch = refreshEpoch;
    _listenBrainzDiscoverSessionCacheKey = sessionKey;
    _listenBrainzDiscoverMatchCache.clear();
    _listenBrainzLocalCandidateCache = null;
    _listenBrainzLocalCandidateCacheFingerprint = null;
    _listenBrainzMatchCacheIdentityEpoch = null;
  }

  final shouldLoadPersistentCache =
      refreshEpoch == 0 || _listenBrainzForceRematchOnNextRefresh;
  final persistentCached = shouldLoadPersistentCache
      ? await _loadListenBrainzWeeklyCache(
          cacheDao: cacheDao,
          libraryDao: dao,
          userName: sessionKey,
        )
      : const <ListenBrainzDiscoverPlaylist>[];
  if (!active()) return;
  AppLogger.debug(
    'ListenBrainz discover weekly cache '
    '${persistentCached.isEmpty ? 'miss' : 'hit'}: count='
    '${persistentCached.length} sourcePatches='
    '${persistentCached.map((playlist) => playlist.playlist.sourcePatch ?? 'none').join(',')}.',
  );
  final hadPersistentCache = persistentCached.isNotEmpty;
  if (hadPersistentCache) {
    _listenBrainzDiscoverLastVisible = persistentCached;
    yield persistentCached;
  }

  if (networkType == NetworkType.offline) {
    AppLogger.debug(
      'ListenBrainz discover offline: using cached playlists count='
      '${_listenBrainzDiscoverSessionCache?.length ?? persistentCached.length}.',
    );
    yield _listenBrainzDiscoverSessionCache ??
        (persistentCached.isNotEmpty ? persistentCached : null) ??
        const <ListenBrainzDiscoverPlaylist>[];
    return;
  }

  try {
    final normalStartup = refreshEpoch == 0;
    final automaticRefresh = normalStartup;
    if (!automaticRefresh) {
      if (!_listenBrainzForceRematchOnNextRefresh) {
        final cached = _listenBrainzDiscoverSessionCache;
        if (cached != null) {
          yield cached;
          return;
        }
      }
      if (!hadPersistentCache) {
        final loading = _listenBrainzLoadingDiscoverPlaylists();
        _listenBrainzDiscoverLastVisible = loading;
        AppLogger.debug(
          'ListenBrainz discover emitted weekly loading placeholders.',
        );
        yield loading;
      }
      AppLogger.debug(
        'ListenBrainz discover manual refresh bypassed startup sync gate: '
        'epoch=$refreshEpoch.',
      );
      await for (final visible in _resolveListenBrainzWeeklyPlaylists(
        ref: ref,
        cancelToken: cancelToken,
        client: client,
        api: api,
        dao: dao,
        cacheDao: cacheDao,
        userName: userName,
        sessionKey: sessionKey,
        token: tokenText,
        cachedPlaylists: persistentCached,
        automaticRefresh: false,
        emitProgressiveSearchUpdates: true,
      )) {
        yield visible;
      }
      return;
    }

    AppLogger.debug(
      'ListenBrainz discover background resolver scheduled: '
      'user=$sessionKey epoch=$refreshEpoch.',
    );
    await Future<void>.delayed(Duration.zero);
    if (!active()) {
      return;
    }
    if (!hadPersistentCache) {
      final loading = _listenBrainzLoadingDiscoverPlaylists();
      _listenBrainzDiscoverLastVisible = loading;
      AppLogger.debug(
        'ListenBrainz discover emitted weekly loading placeholders.',
      );
      yield loading;
    }
    while (ref.read(listenBrainzDiscoverStartupSyncStateProvider).isRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!active()) {
        return;
      }
    }
    final openedSyncState = ref.read(
      listenBrainzDiscoverStartupSyncStateProvider,
    );
    AppLogger.debug(
      'ListenBrainz discover sync gate opened: '
      'status=${openedSyncState.status.name} '
      'stage=${openedSyncState.stage.name}.',
    );
    await _awaitListenBrainzStartupIdle(
      ref,
      !hadPersistentCache || _listenBrainzSkipStartupIdleOnce
          ? Duration.zero
          : startupIdleDelay,
    );
    if (_listenBrainzSkipStartupIdleOnce) {
      _listenBrainzSkipStartupIdleOnce = false;
    }
    if (!active()) {
      return;
    }
    AppLogger.debug(
      'ListenBrainz discover startup idle elapsed; beginning background refresh.',
    );

    await for (final visible in _resolveListenBrainzWeeklyPlaylists(
      ref: ref,
      cancelToken: cancelToken,
      client: client,
      api: api,
      dao: dao,
      cacheDao: cacheDao,
      userName: userName,
      sessionKey: sessionKey,
      token: tokenText,
      cachedPlaylists: persistentCached,
      automaticRefresh: true,
      emitProgressiveSearchUpdates: false,
    )) {
      if (hadPersistentCache &&
          _listenBrainzDiscoverPlaylistsContentEqual(
            visible,
            persistentCached,
          )) {
        _listenBrainzDiscoverSessionCache = visible;
        continue;
      }
      _listenBrainzDiscoverLastVisible = visible;
      yield visible;
    }
  } on DioException catch (error) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      AppLogger.warning(
        'ListenBrainz discover disabled: token rejected with status=$status.',
      );
      await db.appSettingsDao.updateListenBrainzScrobblingState(
        enabled: false,
        tokenValid: false,
        clearUserName: true,
      );
      yield const <ListenBrainzDiscoverPlaylist>[];
      return;
    }
    if (_listenBrainzDiscoverSessionCache != null) {
      AppLogger.debug(
        'ListenBrainz discover fetch failed: using cached playlists count='
        '${_listenBrainzDiscoverSessionCache!.length}.',
      );
      yield _listenBrainzDiscoverSessionCache!;
      return;
    }
    if (_listenBrainzDiscoverLastVisible != null) {
      yield _listenBrainzDiscoverLastVisible!;
      return;
    }
    rethrow;
  }
}

Stream<List<ListenBrainzDiscoverPlaylist>> _resolveListenBrainzWeeklyPlaylists({
  required Ref ref,
  required CancelToken cancelToken,
  required ListenBrainzApiClient client,
  required SubsonicApiClient? api,
  required LibraryDao dao,
  required CacheDao cacheDao,
  required String userName,
  required String sessionKey,
  required String token,
  required List<ListenBrainzDiscoverPlaylist> cachedPlaylists,
  required bool automaticRefresh,
  required bool emitProgressiveSearchUpdates,
}) async* {
  var resolvedPlaylists = <ListenBrainzDiscoverPlaylist>[];
  final playlistMetadata = await _fetchListenBrainzPlaylistMetadata(
    client: client,
    userName: userName,
    token: token,
    cancelToken: cancelToken,
  );
  if (!ref.mounted) {
    return;
  }
  final targetMetadata = _selectListenBrainzShowcaseMetadata(playlistMetadata);
  AppLogger.debug(
    'ListenBrainz discover metadata fetched count='
    '${playlistMetadata.length} selectedTargets=${targetMetadata.length}.',
  );
  final hasPersistentCache = cachedPlaylists.isNotEmpty;
  // Whether this resolve searches the server (search3). A new week always
  // does; an unchanged week only for its daily recheck, which also looks for
  // server copies of remote matches. Every resolve checks the library.
  var searchServer = true;
  var recheckRemote = false;
  if (hasPersistentCache &&
      _listenBrainzMetadataMatchesCachedPlaylists(
        targetMetadata,
        cachedPlaylists,
      )) {
    final localRecheckCount = _listenBrainzLocalRecheckCount(cachedPlaylists);
    final searchDue = _listenBrainzSearchRecheckDue(
      cachedPlaylists,
      DateTime.now(),
    );
    AppLogger.debug(
      'ListenBrainz discover metadata check result=unchanged count='
      '${targetMetadata.length}.',
    );
    AppLogger.debug(
      'ListenBrainz discover cached recheck: local=$localRecheckCount '
      'searchDue=$searchDue.',
    );
    if (localRecheckCount == 0 && !searchDue) {
      _listenBrainzDiscoverSessionCache = cachedPlaylists;
      _listenBrainzForceRematchOnNextRefresh = false;
      yield cachedPlaylists;
      return;
    }
    resolvedPlaylists = cachedPlaylists;
    searchServer = searchDue;
    recheckRemote = searchDue;
  } else {
    if (hasPersistentCache) {
      AppLogger.debug(
        'ListenBrainz discover metadata check result=changed count='
        '${targetMetadata.length}.',
      );
    }
    if (targetMetadata.isEmpty) {
      AppLogger.debug(
        'ListenBrainz discover skipped: ListenBrainz returned no weekly '
        'recommendation playlists.',
      );
      _listenBrainzDiscoverLastVisible = const <ListenBrainzDiscoverPlaylist>[];
      _listenBrainzDiscoverSessionCache =
          const <ListenBrainzDiscoverPlaylist>[];
      await _saveListenBrainzWeeklyCache(
        cacheDao: cacheDao,
        userName: sessionKey,
        playlists: const <ListenBrainzDiscoverPlaylist>[],
      );
      yield const <ListenBrainzDiscoverPlaylist>[];
      return;
    }
    final detailQueue = _BoundedAsyncQueue(
      _listenBrainzDiscoverPlaylistDetailParallelism,
    );
    final detailResults = await Future.wait(
      targetMetadata.map(
        (metadata) => detailQueue.run(
          () => _fetchListenBrainzTargetDetail(
            client: client,
            metadata: metadata,
            token: token,
            cancelToken: cancelToken,
          ),
        ),
      ),
    );
    if (!ref.mounted) {
      return;
    }
    resolvedPlaylists = detailResults
        .whereType<ListenBrainzDiscoverPlaylist>()
        .toList(growable: false);
  }

  // Only songs that could match an unresolved recommendation.
  final localSongsSnapshot = await dao.getTrackMatchCandidates(
    _listenBrainzUnresolvedMatchQueries(resolvedPlaylists),
  );
  if (!ref.mounted) {
    return;
  }
  final localCandidates = await _loadListenBrainzLocalCandidateSnapshot(
    localSongsSnapshot,
  );
  final beforeLocalMatched = _listenBrainzMatchedRecommendationCount(
    resolvedPlaylists,
  );
  resolvedPlaylists = await Future.wait(
    resolvedPlaylists.map(
      (playlist) => _resolveListenBrainzTracksFromLocalSnapshot(
        playlist: playlist,
        localCandidates: localCandidates,
      ),
    ),
  );
  if (!ref.mounted) {
    return;
  }
  final afterLocalMatched = _listenBrainzMatchedRecommendationCount(
    resolvedPlaylists,
  );
  AppLogger.debug(
    'ListenBrainz discover local pass matched='
    '${afterLocalMatched - beforeLocalMatched} totalMatched=$afterLocalMatched.',
  );

  if (searchServer) {
    final searchCount = resolvedPlaylists.fold<int>(0, (sum, playlist) {
      return sum +
          playlist.recommendations.where((recommendation) {
            return _listenBrainzRecommendationNeedsResolution(recommendation) ||
                (recheckRemote && _listenBrainzIsRemoteMatch(recommendation));
          }).length;
    });
    if (searchCount > 0) {
      final searchParallelism = automaticRefresh
          ? _listenBrainzDiscoverAutomaticSearchParallelism
          : _listenBrainzDiscoverSearchParallelism;
      AppLogger.debug(
        'ListenBrainz discover search3 start: '
        'tracks=$searchCount recheckRemote=$recheckRemote '
        'concurrency=$searchParallelism.',
      );
      await for (final updated in _resolveListenBrainzTrackSearchMisses(
        api: api,
        dao: dao,
        playlists: resolvedPlaylists,
        maxConcurrent: searchParallelism,
        emitProgressiveUpdates: emitProgressiveSearchUpdates,
        recheckRemote: recheckRemote,
      )) {
        if (!ref.mounted) {
          return;
        }
        resolvedPlaylists = updated;
      }
      if (!ref.mounted) {
        return;
      }
    }
    final searchedAt = DateTime.now();
    resolvedPlaylists = resolvedPlaylists
        .map((playlist) => playlist.copyWith(searchedAt: searchedAt))
        .toList(growable: false);
  }

  resolvedPlaylists = resolvedPlaylists
      .map((playlist) => playlist.copyWith(matchingComplete: true))
      .toList(growable: false);
  for (final discoverPlaylist in resolvedPlaylists) {
    final matchedCount = discoverPlaylist.matchedCount;
    AppLogger.debug(
      'ListenBrainz discover target ready: '
      'sourcePatch="${discoverPlaylist.playlist.sourcePatch ?? 'unknown'}" '
      'title="${discoverPlaylist.playlist.title}" '
      'detailTracks=${discoverPlaylist.playlist.tracks.length} '
      'tracks=${discoverPlaylist.totalCount} matched=$matchedCount.',
    );
    if (matchedCount == 0) {
      AppLogger.debug(
        'ListenBrainz discover kept target without playable matches: '
        'sourcePatch="${discoverPlaylist.playlist.sourcePatch ?? 'unknown'}" '
        'title="${discoverPlaylist.playlist.title}".',
      );
    }
  }
  final visible = _visibleListenBrainzDiscoverPlaylists(resolvedPlaylists);
  _listenBrainzDiscoverLastVisible = visible;
  _listenBrainzDiscoverSessionCache = visible;
  _listenBrainzForceRematchOnNextRefresh = false;
  await _saveListenBrainzWeeklyCache(
    cacheDao: cacheDao,
    userName: sessionKey,
    playlists: visible,
  );
  AppLogger.debug(
    'ListenBrainz discover weekly cache saved: matched='
    '${visible.fold<int>(0, (sum, playlist) => sum + playlist.matchedCount)} '
    'total=${visible.fold<int>(0, (sum, playlist) => sum + playlist.totalCount)}.',
  );
  yield visible;
}

@visibleForTesting
final listenBrainzDiscoverProvider =
    FutureProvider<List<ListenBrainzDiscoverPlaylist>>((ref) async {
      var latest = const <ListenBrainzDiscoverPlaylist>[];
      await for (final value in _listenBrainzDiscoverStream(ref)) {
        latest = value;
      }
      return latest;
    });

Future<ListenBrainzDiscoverPlaylist> _rematchListenBrainzPlaylist(
  Ref ref,
  ListenBrainzDiscoverPlaylist existing,
) async {
  final settings =
      ref.read(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  final credentialStore = ref.read(externalScrobbleCredentialStoreProvider);
  final token = (await credentialStore.readListenBrainzToken())?.trim() ?? '';
  final userName = settings.listenBrainzUserName?.trim();
  if (token.isEmpty || userName == null || userName.isEmpty) {
    throw StateError('ListenBrainz credentials are unavailable.');
  }
  final sourcePatch = existing.playlist.sourcePatch?.trim();
  if (sourcePatch == null || sourcePatch.isEmpty) {
    throw StateError('ListenBrainz playlist is missing a source patch.');
  }

  final db = ref.read(navisDatabaseProvider);
  final client = ref.read(listenBrainzApiClientProvider);
  final api = ref.read(subsonicApiProvider);
  var playlist = await _fetchListenBrainzTargetDetail(
    client: client,
    metadata: existing.playlist,
    token: token,
  );
  playlist ??= existing.copyWith(
    recommendations: existing.playlist.tracks
        .take(_listenBrainzDiscoverTrackPreviewLimit)
        .map(
          (track) => ListenBrainzResolvedRecommendation(
            track: track,
            status: ListenBrainzRecommendationMatchStatus.pending,
          ),
        )
        .toList(growable: false),
    matchingComplete: false,
  );
  if (playlist.totalCount == 0) {
    throw StateError('ListenBrainz playlist has no tracks to match.');
  }

  _clearListenBrainzPlaylistMatchCache(playlist.playlist);
  final localSongsSnapshot = await db.libraryDao.getTrackMatchCandidates(
    _listenBrainzUnresolvedMatchQueries(<ListenBrainzDiscoverPlaylist>[
      playlist,
    ]),
  );
  final localCandidates = await _loadListenBrainzLocalCandidateSnapshot(
    localSongsSnapshot,
  );
  var resolved = await _resolveListenBrainzTracksFromLocalSnapshot(
    playlist: playlist,
    localCandidates: localCandidates,
    allowCachedMatches: false,
  );
  await for (final updated in _resolveListenBrainzTrackSearchMisses(
    api: api,
    dao: db.libraryDao,
    playlists: <ListenBrainzDiscoverPlaylist>[resolved],
    maxConcurrent: _listenBrainzDiscoverSearchParallelism,
    emitProgressiveUpdates: false,
    allowCachedMatches: false,
    recheckRemote: true,
  )) {
    resolved = updated.single;
  }
  resolved = resolved.copyWith(
    matchingComplete: true,
    searchedAt: DateTime.now(),
  );
  await _saveListenBrainzWeeklyCache(
    cacheDao: db.cacheDao,
    userName: userName.toLowerCase(),
    playlists: _replaceListenBrainzPlaylist(
      _listenBrainzDiscoverSessionCache ??
          <ListenBrainzDiscoverPlaylist>[resolved],
      resolved,
    )!,
  );
  AppLogger.debug(
    'ListenBrainz manual rematch complete: sourcePatch="$sourcePatch" '
    'matched=${resolved.matchedCount} total=${resolved.totalCount}.',
  );
  return resolved;
}

Future<List<ListenBrainzPlaylist>> _fetchListenBrainzPlaylistMetadata({
  required ListenBrainzApiClient client,
  required String userName,
  required String token,
  CancelToken? cancelToken,
}) async {
  try {
    final recommendations = await client.getRecommendationPlaylists(
      userName: userName,
      userToken: token,
      cancelToken: cancelToken,
    );
    AppLogger.debug(
      'ListenBrainz discover recommendations fetched count='
      '${recommendations.length}.',
    );
    AppLogger.debug(
      'ListenBrainz discover recommendation sourcePatches='
      '${recommendations.map((playlist) => playlist.sourcePatch ?? 'none').toSet().join(',')}.',
    );
    return recommendations;
  } on DioException catch (error) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      rethrow;
    }
    AppLogger.debug(
      'ListenBrainz discover recommendations fetch failed: '
      'status=${status ?? 'unknown'}.',
    );
  }

  return const <ListenBrainzPlaylist>[];
}

Future<ListenBrainzDiscoverPlaylist?> _fetchListenBrainzTargetDetail({
  required ListenBrainzApiClient client,
  required ListenBrainzPlaylist metadata,
  required String token,
  CancelToken? cancelToken,
}) async {
  final identifier = metadata.identifier.trim();
  if (identifier.isEmpty) {
    return null;
  }
  final ListenBrainzPlaylist playlistDetail;
  try {
    playlistDetail = await client.getPlaylist(
      identifier,
      fetchMetadata: true,
      userToken: token,
      cancelToken: cancelToken,
    );
  } on DioException catch (error) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      rethrow;
    }
    AppLogger.debug(
      'ListenBrainz discover skipped target detail fetch: '
      'title="${metadata.title}" status=${status ?? 'unknown'}.',
    );
    return null;
  }

  final playlist = playlistDetail.copyWith(
    sourcePatch: playlistDetail.sourcePatch ?? metadata.sourcePatch,
  );
  final tracks = playlist.tracks
      .take(_listenBrainzDiscoverTrackPreviewLimit)
      .toList(growable: false);
  if (tracks.isEmpty) {
    AppLogger.debug(
      'ListenBrainz discover removed target: '
      'sourcePatch="${metadata.sourcePatch ?? 'unknown'}" '
      'title="${playlist.title}" reason=zero_tracks.',
    );
    return null;
  }

  return ListenBrainzDiscoverPlaylist(
    playlist: playlist,
    recommendations: tracks
        .map(
          (track) => ListenBrainzResolvedRecommendation(
            track: track,
            status: ListenBrainzRecommendationMatchStatus.pending,
          ),
        )
        .toList(growable: false),
  );
}

Future<ListenBrainzDiscoverPlaylist>
_resolveListenBrainzTracksFromLocalSnapshot({
  required ListenBrainzDiscoverPlaylist playlist,
  required _ListenBrainzLocalCandidateSnapshot localCandidates,
  bool allowCachedMatches = true,
}) async {
  final recommendations = <ListenBrainzResolvedRecommendation>[];
  for (
    var recommendationIndex = 0;
    recommendationIndex < playlist.recommendations.length;
    recommendationIndex++
  ) {
    final recommendation = playlist.recommendations[recommendationIndex];
    // Remote and unmatched tracks are checked against the library on every
    // pass, so a remote match switches to the library copy once its album is
    // on the server and synced.
    if (recommendation.hasServerSong) {
      recommendations.add(recommendation);
      continue;
    }
    final cacheKey = _listenBrainzMatchCacheKey(
      playlist.playlist,
      recommendation.track,
    );
    final cached = allowCachedMatches
        ? _listenBrainzDiscoverMatchCache[cacheKey]
        : null;
    if (cached != null && cached.hasServerSong) {
      recommendations.add(cached);
      continue;
    }
    final localMatch = _pickListenBrainzTrackMatch(
      recommendation.track,
      localCandidates.candidatesFor(
        _listenBrainzTrackMatchQuery(recommendation.track),
      ),
    );
    if (localMatch.isPlayable) {
      _listenBrainzDiscoverMatchCache[cacheKey] = localMatch;
    }
    // Without a library match a remote match stays playable as it was.
    recommendations.add(localMatch.isPlayable ? localMatch : recommendation);
    if ((recommendationIndex + 1) %
            _listenBrainzDiscoverLocalMatchYieldBatchSize ==
        0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return playlist.copyWith(recommendations: recommendations);
}

Stream<List<ListenBrainzDiscoverPlaylist>>
_resolveListenBrainzTrackSearchMisses({
  required SubsonicApiClient? api,
  required LibraryDao dao,
  required List<ListenBrainzDiscoverPlaylist> playlists,
  required int maxConcurrent,
  required bool emitProgressiveUpdates,
  bool allowCachedMatches = true,
  bool recheckRemote = false,
}) async* {
  var current = playlists
      .map(
        (playlist) => playlist.copyWith(
          recommendations: playlist.recommendations.toList(growable: false),
        ),
      )
      .toList(growable: false);
  if (api == null) {
    current = current
        .map(
          (playlist) => playlist.copyWith(
            recommendations: playlist.recommendations
                .map(
                  (recommendation) =>
                      _listenBrainzRecommendationNeedsResolution(recommendation)
                      ? ListenBrainzResolvedRecommendation(
                          track: recommendation.track,
                          status:
                              ListenBrainzRecommendationMatchStatus.unmatched,
                        )
                      : recommendation,
                )
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
    yield current;
    return;
  }

  final searchQueue = _BoundedAsyncQueue(maxConcurrent);
  final pending =
      <
        int,
        Future<
          ({
            int taskId,
            int playlistIndex,
            int recommendationIndex,
            ListenBrainzResolvedRecommendation recommendation,
          })
        >
      >{};
  var nextTaskId = 0;

  for (var playlistIndex = 0; playlistIndex < current.length; playlistIndex++) {
    final playlist = current[playlistIndex];
    for (
      var recommendationIndex = 0;
      recommendationIndex < playlist.recommendations.length;
      recommendationIndex++
    ) {
      final recommendation = playlist.recommendations[recommendationIndex];
      if (!_listenBrainzRecommendationNeedsResolution(recommendation) &&
          !(recheckRemote && _listenBrainzIsRemoteMatch(recommendation))) {
        continue;
      }
      final taskId = nextTaskId++;
      pending[taskId] = searchQueue.run(
        () => _resolveListenBrainzRemoteSearchMiss(
          api: api,
          playlist: playlist.playlist,
          recommendation: recommendation,
          taskId: taskId,
          playlistIndex: playlistIndex,
          recommendationIndex: recommendationIndex,
          allowCachedMatches: allowCachedMatches,
        ),
      );
    }
  }

  var completionsSinceYield = 0;
  final hadSearchWork = nextTaskId > 0;
  while (pending.isNotEmpty) {
    final completed = await Future.any(pending.values);
    final removedTask = pending.remove(completed.taskId);
    if (removedTask == null) {
      continue;
    }
    final playlist = current[completed.playlistIndex];
    final recommendations = playlist.recommendations.toList(growable: true);
    recommendations[completed.recommendationIndex] = completed.recommendation;
    current = current.toList(growable: true);
    current[completed.playlistIndex] = playlist.copyWith(
      recommendations: recommendations.toList(growable: false),
    );
    current = current.toList(growable: false);
    completionsSinceYield++;
    if (!emitProgressiveUpdates) {
      continue;
    }
    if (pending.isEmpty ||
        completionsSinceYield >= _listenBrainzDiscoverSearchEmitBatchSize) {
      completionsSinceYield = 0;
      current = await _persistListenBrainzSearchMatches(dao, current);
      yield current;
    }
  }
  if (!emitProgressiveUpdates && hadSearchWork) {
    current = await _persistListenBrainzSearchMatches(dao, current);
    yield current;
  }
}

Future<
  ({
    int taskId,
    int playlistIndex,
    int recommendationIndex,
    ListenBrainzResolvedRecommendation recommendation,
  })
>
_resolveListenBrainzRemoteSearchMiss({
  required SubsonicApiClient api,
  required ListenBrainzPlaylist playlist,
  required ListenBrainzResolvedRecommendation recommendation,
  required int taskId,
  required int playlistIndex,
  required int recommendationIndex,
  required bool allowCachedMatches,
}) async {
  final track = recommendation.track;
  // A remote match is searched again only to find a copy on the server; it is
  // never replaced by another remote result or lost to a failed search.
  final upgradeOnly = _listenBrainzIsRemoteMatch(recommendation);
  final cacheKey = _listenBrainzMatchCacheKey(playlist, track);
  final cached = allowCachedMatches
      ? _listenBrainzDiscoverMatchCache[cacheKey]
      : null;
  if (cached != null &&
      cached.isPlayable &&
      !(upgradeOnly && _listenBrainzIsRemoteMatch(cached))) {
    return (
      taskId: taskId,
      playlistIndex: playlistIndex,
      recommendationIndex: recommendationIndex,
      recommendation: cached,
    );
  }
  try {
    final query = <String>[
      track.title,
      if (track.creator != null) track.creator!,
      if (track.album != null) track.album!,
    ].join(' ');
    final search = await api.search3(
      query: query,
      artistCount: 0,
      albumCount: 0,
      songCount: _listenBrainzDiscoverSearchSongCount,
    );
    final candidates = search.songs
        .map(_listenBrainzRemoteCandidate)
        .toList(growable: false);
    final onServer = candidates
        .where((candidate) => isServerAddressableSongId(candidate.song.id))
        .toList(growable: false);
    // Prefer a copy on the server over an equally good remote one.
    var match = onServer.isEmpty
        ? null
        : _pickListenBrainzTrackMatch(track, onServer);
    if (match == null || !match.isPlayable) {
      match = upgradeOnly
          ? recommendation
          : _pickListenBrainzTrackMatch(track, candidates);
    }
    AppLogger.debug(
      'ListenBrainz discover search3 result: query="$query" '
      'returned=${search.songs.length} status=${match.status.name} '
      'playable=${match.isPlayable}.',
    );
    if (match.isPlayable) {
      _listenBrainzDiscoverMatchCache[cacheKey] = match;
    }
    return (
      taskId: taskId,
      playlistIndex: playlistIndex,
      recommendationIndex: recommendationIndex,
      recommendation: match,
    );
  } on Object catch (error) {
    AppLogger.debug(
      'ListenBrainz discover search3 failed: '
      'query="${track.title} ${track.creator ?? ''}". error=$error',
    );
    final unmatched = upgradeOnly
        ? recommendation
        : ListenBrainzResolvedRecommendation(
            track: track,
            status: ListenBrainzRecommendationMatchStatus.unmatched,
          );
    return (
      taskId: taskId,
      playlistIndex: playlistIndex,
      recommendationIndex: recommendationIndex,
      recommendation: unmatched,
    );
  }
}

ListenBrainzResolvedRecommendation _pickListenBrainzTrackMatch(
  ListenBrainzPlaylistTrack track,
  List<_ListenBrainzSongCandidate> candidates,
) {
  final query = _listenBrainzTrackMatchQuery(track);
  final match = pickBestTrackMatch(track: query, candidates: candidates);
  AppLogger.debug(
    'ListenBrainz discover match scoring: title="${track.title}" '
    'artist="${track.creator ?? ''}" candidates=${candidates.length} '
    'status=${match.status.name}.',
  );
  return switch (match.status) {
    TrackMatchStatus.matched => ListenBrainzResolvedRecommendation(
      track: track,
      status: ListenBrainzRecommendationMatchStatus.matched,
      song: match.song,
      tableSong: match.tableSong,
    ),
    TrackMatchStatus.ambiguous => ListenBrainzResolvedRecommendation(
      track: track,
      status: ListenBrainzRecommendationMatchStatus.ambiguous,
    ),
    TrackMatchStatus.unmatched => ListenBrainzResolvedRecommendation(
      track: track,
      status: ListenBrainzRecommendationMatchStatus.unmatched,
    ),
  };
}

/// Title and artist of every recommendation without a song on the server,
/// remote matches included.
Iterable<({String title, String artist})> _listenBrainzUnresolvedMatchQueries(
  List<ListenBrainzDiscoverPlaylist> playlists,
) sync* {
  for (final playlist in playlists) {
    for (final recommendation in playlist.recommendations) {
      if (recommendation.hasServerSong) continue;
      final query = _listenBrainzTrackMatchQuery(recommendation.track);
      yield (title: query.title, artist: query.artist);
    }
  }
}

TrackMatchQuery _listenBrainzTrackMatchQuery(ListenBrainzPlaylistTrack track) {
  return TrackMatchQuery(
    title: track.title,
    artist: track.creator ?? '',
    album: track.album,
    durationSeconds: track.durationSeconds,
    recordingMbid: track.recordingMbid,
  );
}

Future<List<ListenBrainzDiscoverPlaylist>> _persistListenBrainzSearchMatches(
  LibraryDao dao,
  List<ListenBrainzDiscoverPlaylist> playlists,
) async {
  final songsById = <String, Song>{};
  final recordingMbidsBySongId = <String, String>{};
  for (final playlist in playlists) {
    for (final recommendation in playlist.recommendations) {
      final song = recommendation.song;
      if (recommendation.tableSong != null ||
          song == null ||
          !isServerAddressableSongId(song.id)) {
        continue;
      }
      songsById[song.id] = song;
      final recordingMbid = recommendation.track.recordingMbid?.trim();
      if (recordingMbid != null && recordingMbid.isNotEmpty) {
        recordingMbidsBySongId[song.id] = recordingMbid;
      }
    }
  }
  if (songsById.isEmpty) {
    return playlists;
  }

  await persistProvisionalSearchSongs(
    dao,
    songsById.values,
    recordingMbidsBySongId: recordingMbidsBySongId,
  );

  return playlists
      .map(
        (playlist) => playlist.copyWith(
          recommendations: playlist.recommendations
              .map((recommendation) {
                final song = recommendation.song;
                if (recommendation.tableSong != null ||
                    song == null ||
                    !songsById.containsKey(song.id)) {
                  return recommendation;
                }
                final persisted = recommendation.copyWith(
                  tableSong: provisionalSongTableData(song),
                );
                _listenBrainzDiscoverMatchCache[_listenBrainzMatchCacheKey(
                      playlist.playlist,
                      recommendation.track,
                    )] =
                    persisted;
                return persisted;
              })
              .toList(growable: false),
        ),
      )
      .toList(growable: false);
}

typedef _ListenBrainzSongCandidate = TrackMatchCandidate;
typedef _ListenBrainzLocalCandidateSnapshot = LocalTrackMatchSnapshot;

_ListenBrainzSongCandidate _listenBrainzRemoteCandidate(Song song) {
  return TrackMatchCandidate.fromSong(song);
}

String _listenBrainzMatchCacheKey(
  ListenBrainzPlaylist playlist,
  ListenBrainzPlaylistTrack track,
) {
  _ensureListenBrainzIdentityCacheEpoch();
  final sourcePatch = playlist.sourcePatch?.trim() ?? '';
  final playlistId = playlist.identifier.trim();
  final identity =
      track.recordingMbid?.trim() ??
      track.recordingMsid?.trim() ??
      '${track.title}|${track.creator ?? ''}|${track.album ?? ''}|${track.durationMs ?? ''}';
  return '${SongIdentityCacheEpoch.value}|$sourcePatch|$playlistId|$identity';
}

void _clearListenBrainzPlaylistMatchCache(ListenBrainzPlaylist playlist) {
  final keys = playlist.tracks
      .map((track) => _listenBrainzMatchCacheKey(playlist, track))
      .toSet();
  _listenBrainzDiscoverMatchCache.removeWhere((key, _) => keys.contains(key));
}

void _ensureListenBrainzIdentityCacheEpoch() {
  final epoch = SongIdentityCacheEpoch.value;
  if (_listenBrainzMatchCacheIdentityEpoch == epoch) {
    return;
  }
  _listenBrainzDiscoverMatchCache.clear();
  _listenBrainzLocalCandidateCache = null;
  _listenBrainzLocalCandidateCacheFingerprint = null;
  _listenBrainzMatchCacheIdentityEpoch = epoch;
}

/// An order-independent fingerprint of the fields the local candidate
/// snapshot depends on. It keys an in-memory, per-run cache, so it hashes in
/// one pass instead of building, sorting and joining a string per song.
@visibleForTesting
String listenBrainzLocalCandidateFingerprint(List<SongsTableData> songs) {
  var sum = 0;
  var xor = 0;
  for (final song in songs) {
    final hash = Object.hash(song.id, song.recordingMbid, song.isProvisional);
    sum = (sum + hash) & 0x1FFFFFFFFFFFFF;
    xor ^= hash;
  }
  return '${songs.length}:$sum:$xor';
}

Future<_ListenBrainzLocalCandidateSnapshot>
_loadListenBrainzLocalCandidateSnapshot(List<SongsTableData> songs) async {
  _ensureListenBrainzIdentityCacheEpoch();
  final joinedFingerprint = listenBrainzLocalCandidateFingerprint(songs);
  if (_listenBrainzLocalCandidateCache != null &&
      _listenBrainzLocalCandidateCacheFingerprint == joinedFingerprint) {
    return _listenBrainzLocalCandidateCache!;
  }
  final snapshot = await _ListenBrainzLocalCandidateSnapshot.fromSongsAsync(
    songs,
  );
  _listenBrainzLocalCandidateCache = snapshot;
  _listenBrainzLocalCandidateCacheFingerprint = joinedFingerprint;
  return snapshot;
}

/// Starred / liked songs from local DB (limit 5 for home preview).
final homeLikedSongsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchStarredSongs(limit: 5);
});

/// Recently added albums from the server API.
final homeRecentlyAddedProvider = FutureProvider<List<Album>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Album>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return await api.getAlbumList2(
    type: 'newest',
    size: 20,
    cancelToken: cancelToken,
  );
});

/// Recently played **albums** derived from local play history.
final homeRecentlyPlayedAlbumsProvider = StreamProvider<List<AlbumsTableData>>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).historyDao;
  return dao.watchRecentlyPlayedAlbums(limit: 20);
});

/// Re-picks the calling random row once each library sync finishes (never
/// mid-sync). Deferred so a sync transition cannot invalidate it while Home is
/// building.
void _repickAfterLibrarySync(Ref ref) {
  ref.listen<LibrarySyncState>(librarySyncControllerProvider, (previous, next) {
    final finished =
        next.status == LibrarySyncStatus.succeeded ||
        next.status == LibrarySyncStatus.partial;
    if (finished && previous?.status != next.status) {
      unawaited(
        Future<void>(() {
          if (ref.mounted) ref.invalidateSelf();
        }),
      );
    }
  });
}

/// The Home Random Albums row: its own server draw, separate from
/// [homeRandomAlbumsProvider] (You Might Like falls back to that list).
final homeRandomAlbumListProvider = FutureProvider<List<Album>>((ref) async {
  _repickAfterLibrarySync(ref);
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Album>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return await api.getAlbumList2(
    type: 'random',
    size: 20,
    cancelToken: cancelToken,
  );
});

/// Random albums from the server API.
final homeRandomAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Album>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return await api.getAlbumList2(
    type: 'random',
    size: 20,
    cancelToken: cancelToken,
  );
});

/// Most played songs from local DB ordered by playCount (limit 5).
final homeMostPlayedSongsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchMostPlayedSongs(limit: 5);
});

final homeDownloadedLikedSongsProvider = StreamProvider<List<SongsTableData>>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  final downloadedSongIds =
      ref.watch(downloadedSongIdsProvider).asData?.value ?? const <String>{};
  return dao.watchAllStarredSongs().map(
    (songs) => songs
        .where((song) => downloadedSongIds.contains(song.id))
        .take(5)
        .toList(growable: false),
  );
});

final homeDownloadedRecentlyAddedAlbumsProvider =
    StreamProvider<List<AlbumsTableData>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final downloadedAlbumIds =
          ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
          const <String>{};
      return dao
          .watchAlbumsSorted(sort: AlbumSortOrder.recentlyAdded)
          .map(
            (albums) => albums
                .where((album) => downloadedAlbumIds.contains(album.id))
                .take(20)
                .toList(growable: false),
          );
    });

final homeDownloadedRecentlyPlayedAlbumsProvider =
    StreamProvider<List<AlbumsTableData>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).historyDao;
      final downloadedAlbumIds =
          ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
          const <String>{};
      return dao
          .watchRecentlyPlayedAlbums(limit: null)
          .map(
            (albums) => albums
                .where((album) => downloadedAlbumIds.contains(album.id))
                .take(20)
                .toList(growable: false),
          );
    });

/// One-shot snapshot (like You Might Like): albums-table writes must not
/// reshuffle the row; only a finished sync or a refresh re-picks.
final homeDownloadedRandomAlbumsProvider =
    FutureProvider<List<AlbumsTableData>>((ref) async {
      _repickAfterLibrarySync(ref);
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final downloadedAlbumIds =
          ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
          const <String>{};
      final albums = (await dao.getAllAlbums())
          .where((album) => downloadedAlbumIds.contains(album.id))
          .toList(growable: true);
      albums.shuffle(Random());
      return albums.take(20).toList(growable: false);
    });

// Stable partition: retain each source's random order within both groups.
List<HomeRandomShowcaseAlbum> _selectHomeRandomShowcaseAlbums(
  Iterable<HomeRandomShowcaseAlbum> albums,
) {
  final preferred = <HomeRandomShowcaseAlbum>[];
  final shorter = <HomeRandomShowcaseAlbum>[];
  for (final album in albums) {
    if ((album.songCount ?? _homeRandomShowcaseMinSongCount) >=
        _homeRandomShowcaseMinSongCount) {
      preferred.add(album);
    } else {
      shorter.add(album);
    }
  }
  return [
    ...preferred,
    ...shorter,
  ].take(_homeRandomShowcaseLimit).toList(growable: false);
}

final homeRandomAlbumShowcaseProvider =
    FutureProvider.family<
      List<HomeRandomShowcaseAlbum>,
      ({bool downloadedOnly, bool likedOnly})
    >((ref, filters) async {
      final downloadedOnly = filters.downloadedOnly;
      final likedOnly = filters.likedOnly;
      final networkType = ref.watch(networkTypeProvider);
      final shuffleSeed = ref.watch(homeRandomShowcaseShuffleSeedProvider);
      final localPreferred =
          downloadedOnly || likedOnly || networkType == NetworkType.offline;

      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final allAlbums = await dao.getAllAlbums();

      final downloadedAlbumIds = downloadedOnly
          ? (ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
                const <String>{})
          : const <String>{};
      final scopedAlbums = downloadedOnly
          ? allAlbums
                .where((album) => downloadedAlbumIds.contains(album.id))
                .toList(growable: false)
          : allAlbums;
      final scopedById = <String, AlbumsTableData>{
        for (final album in scopedAlbums) album.id: album,
      };
      // Intentional non-reactive snapshot: liking/unliking a song should not
      // reshuffle the random showcase unless an explicit refresh/sync occurs.
      final likedSongsSnapshot =
          ref.read(likedSongsProvider).asData?.value ??
          const <SongsTableData>[];

      if (!localPreferred) {
        final api = ref.watch(subsonicApiProvider);
        if (api != null) {
          final eligibleLikedSongs = likedSongsSnapshot
              .where((song) => song.id.trim().isNotEmpty)
              .toList(growable: true);

          if (eligibleLikedSongs.length >= _homeRandomDiscoveryMinLikedSongs) {
            final discovery = await _buildLikedDiscoveryAlbums(
              api: api,
              likedSongs: eligibleLikedSongs,
              scopedById: scopedById,
              shuffleSeed: shuffleSeed,
            );
            if (discovery.length >= _homeRandomDiscoveryMinResults) {
              return _selectHomeRandomShowcaseAlbums(discovery);
            }
          }

          try {
            final serverRandom = await ref.watch(
              homeRandomAlbumsProvider.future,
            );
            if (serverRandom.isNotEmpty) {
              return _selectHomeRandomShowcaseAlbums(
                serverRandom.map(
                  (album) => HomeRandomShowcaseAlbum.fromServer(
                    album,
                    coverArtRevision:
                        scopedById[album.id]?.coverArtRevision ?? 0,
                  ),
                ),
              );
            }
          } on Exception {
            // Fall back to local candidates when server random fails.
          }
        }
      }

      final candidates = <AlbumsTableData>[];
      if (likedOnly) {
        final deduped = <String, AlbumsTableData>{};

        final likedAlbums = await dao.getLikedAlbums();
        for (final likedAlbum in likedAlbums) {
          final scopedAlbum = scopedById[likedAlbum.id];
          if (scopedAlbum == null) {
            continue;
          }
          deduped[scopedAlbum.id] = scopedAlbum;
        }

        if (deduped.length < _homeRandomShowcaseLimit) {
          final downloadedSongIds = downloadedOnly
              ? (ref.watch(downloadedSongIdsProvider).asData?.value ??
                    const <String>{})
              : const <String>{};

          for (final song in likedSongsSnapshot) {
            if (downloadedOnly && !downloadedSongIds.contains(song.id)) {
              continue;
            }
            final albumId = song.albumId?.trim();
            if (albumId == null || albumId.isEmpty) {
              continue;
            }
            final scopedAlbum = scopedById[albumId];
            if (scopedAlbum == null) {
              continue;
            }
            deduped[scopedAlbum.id] = scopedAlbum;
          }
        }

        candidates.addAll(deduped.values);
      } else {
        candidates.addAll(scopedAlbums);
      }

      final random = Random(
        shuffleSeed ^
            (downloadedOnly ? 0x9e3779b9 : 0) ^
            (likedOnly ? 0x7f4a7c15 : 0) ^
            candidates.length,
      );
      candidates.shuffle(random);
      return _selectHomeRandomShowcaseAlbums(
        candidates.map(HomeRandomShowcaseAlbum.fromLocal),
      );
    });

final homeRandomShowcaseProvider =
    Provider.family<
      AsyncValue<List<HomeRandomShowcaseItem>>,
      ({bool downloadedOnly, bool likedOnly})
    >((ref, filters) {
      final listenBrainz = ref.watch(listenBrainzDiscoverStreamProvider);
      final albumsAsync = ref.watch(homeRandomAlbumShowcaseProvider(filters));
      // Trending is chart music, so it never joins the downloaded-only or
      // liked-only hero, and it is not even fetched under them.
      final trendingTracks = filters.downloadedOnly || filters.likedOnly
          ? null
          : ref.watch(homeTrendingProvider).value;
      final trending = trendingTracks == null
          ? null
          : HomeRandomShowcaseTrending.forHero(trendingTracks);

      List<HomeRandomShowcaseItem>? playlists() {
        final weekly = _listenBrainzShowcasePrefix(ref, filters, listenBrainz);
        if (weekly == null && trending == null) return null;
        return <HomeRandomShowcaseItem>[...?weekly, ?trending];
      }

      return albumsAsync.when(
        loading: () {
          final staged = playlists();
          if (staged != null && staged.isNotEmpty) {
            return AsyncData(staged);
          }
          return const AsyncLoading();
        },
        error: AsyncError.new,
        data: (albums) {
          final prefix = playlists();
          return AsyncData(
            prefix == null
                ? albums
                : <HomeRandomShowcaseItem>[
                    ...prefix,
                    ...albums.take(_homeRandomShowcaseLimit - prefix.length),
                  ],
          );
        },
      );
    });

List<HomeRandomShowcaseItem>? _listenBrainzShowcasePrefix(
  Ref ref,
  ({bool downloadedOnly, bool likedOnly}) filters,
  AsyncValue<List<ListenBrainzDiscoverPlaylist>> listenBrainz,
) {
  if (filters.downloadedOnly || filters.likedOnly) {
    return null;
  }
  final streamItems = listenBrainz.maybeWhen(
    data: (playlists) => <HomeRandomShowcaseListenBrainz>[
      for (final playlist in playlists)
        HomeRandomShowcaseListenBrainz(playlist: playlist),
    ],
    orElse: () => null,
  );
  if (streamItems != null) {
    if (streamItems.isEmpty) {
      final lastVisible = _listenBrainzDiscoverLastVisible;
      if (lastVisible != null && lastVisible.isNotEmpty) {
        return <HomeRandomShowcaseItem>[
          for (final playlist in lastVisible)
            HomeRandomShowcaseListenBrainz(playlist: playlist),
        ];
      }
      return null;
    }
    return <HomeRandomShowcaseItem>[...streamItems];
  }
  final cached = _listenBrainzDiscoverSessionCache;
  if (cached != null && cached.isNotEmpty) {
    return <HomeRandomShowcaseItem>[
      for (final playlist in cached)
        HomeRandomShowcaseListenBrainz(playlist: playlist),
    ];
  }
  final lastVisible = _listenBrainzDiscoverLastVisible;
  if (lastVisible != null) {
    return <HomeRandomShowcaseItem>[
      for (final playlist in lastVisible)
        HomeRandomShowcaseListenBrainz(playlist: playlist),
    ];
  }
  final items = listenBrainz.maybeWhen(
    loading: () => _listenBrainzLoadingShowcaseItems(ref),
    orElse: () => const <HomeRandomShowcaseListenBrainz>[],
  );
  if (items.isEmpty) {
    return null;
  }
  return <HomeRandomShowcaseItem>[...items];
}

List<HomeRandomShowcaseListenBrainz> _listenBrainzLoadingShowcaseItems(
  Ref ref,
) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  if (!settings.listenBrainzTokenValid ||
      settings.listenBrainzUserName?.trim().isEmpty != false ||
      ref.watch(networkTypeProvider) == NetworkType.offline) {
    return const <HomeRandomShowcaseListenBrainz>[];
  }
  return const <HomeRandomShowcaseListenBrainz>[
    HomeRandomShowcaseListenBrainz.loading(
      sourcePatch: 'weekly-exploration',
      displayTitle: 'Weekly Exploration',
    ),
    HomeRandomShowcaseListenBrainz.loading(
      sourcePatch: 'weekly-jams',
      displayTitle: 'Weekly Jams',
    ),
  ];
}

List<ListenBrainzDiscoverPlaylist> _listenBrainzLoadingDiscoverPlaylists() {
  return const <ListenBrainzDiscoverPlaylist>[
    ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: 'weekly-exploration',
        title: 'Weekly Exploration',
        sourcePatch: 'weekly-exploration',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
      recommendations: <ListenBrainzResolvedRecommendation>[],
    ),
    ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: 'weekly-jams',
        title: 'Weekly Jams',
        sourcePatch: 'weekly-jams',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
      recommendations: <ListenBrainzResolvedRecommendation>[],
    ),
  ];
}

Future<List<ListenBrainzDiscoverPlaylist>> _loadListenBrainzWeeklyCache({
  required CacheDao cacheDao,
  required LibraryDao libraryDao,
  required String userName,
}) async {
  final rows = await cacheDao.getListenBrainzWeeklyCacheForUser(userName);
  if (rows.isEmpty) {
    return const <ListenBrainzDiscoverPlaylist>[];
  }
  final bySourcePatch = <String, ListenBrainzDiscoverPlaylist>{};
  for (final row in rows) {
    final playlist = _listenBrainzDiscoverPlaylistFromCache(row);
    if (playlist == null) {
      continue;
    }
    bySourcePatch[row.sourcePatch] = playlist;
  }
  final playlists = _listenBrainzShowcaseSourcePatches
      .map((sourcePatch) => bySourcePatch[sourcePatch])
      .whereType<ListenBrainzDiscoverPlaylist>()
      .toList(growable: false);
  return await _attachListenBrainzLibraryRows(libraryDao, playlists);
}

/// Gives cached matches of songs on the server their current library rows.
///
/// The cache stores only the matched API song. A song the server has since
/// deleted (or that is no longer in the library) becomes unmatched, so it is
/// neither played nor counted as available and the next resolve looks for it
/// again. Remote matches have no library row and keep none.
Future<List<ListenBrainzDiscoverPlaylist>> _attachListenBrainzLibraryRows(
  LibraryDao libraryDao,
  List<ListenBrainzDiscoverPlaylist> playlists,
) async {
  final serverIds = <String>{
    for (final playlist in playlists)
      for (final recommendation in playlist.recommendations)
        if (recommendation.song case final song?
            when isServerAddressableSongId(song.id))
          song.id,
  };
  if (serverIds.isEmpty) {
    return playlists;
  }
  final rowsById = <String, SongsTableData>{
    for (final row in await libraryDao.getSongsByIds(serverIds)) row.id: row,
  };
  return playlists
      .map(
        (playlist) => playlist.copyWith(
          recommendations: playlist.recommendations
              .map((recommendation) {
                final song = recommendation.song;
                if (song == null || !isServerAddressableSongId(song.id)) {
                  return recommendation;
                }
                final row = rowsById[song.id];
                if (row == null || row.serverDeletedAt != null) {
                  return ListenBrainzResolvedRecommendation(
                    track: recommendation.track,
                    status: ListenBrainzRecommendationMatchStatus.unmatched,
                  );
                }
                return recommendation.copyWith(tableSong: row);
              })
              .toList(growable: false),
        ),
      )
      .toList(growable: false);
}

Future<void> _saveListenBrainzWeeklyCache({
  required CacheDao cacheDao,
  required String userName,
  required List<ListenBrainzDiscoverPlaylist> playlists,
}) async {
  await cacheDao.deleteListenBrainzWeeklyCacheForUserSources(
    userName,
    _listenBrainzShowcaseSourcePatches,
  );
  for (final playlist in playlists) {
    final sourcePatch = playlist.playlist.sourcePatch?.trim();
    if (sourcePatch == null || sourcePatch.isEmpty) {
      continue;
    }
    await cacheDao.upsertListenBrainzWeeklyCache(
      ListenBrainzWeeklyCacheTableCompanion.insert(
        listenBrainzUserName: userName,
        sourcePatch: sourcePatch,
        playlistIdentifier: playlist.playlist.identifier,
        title: playlist.playlist.title,
        weekMarker: Value(_listenBrainzWeekMarker(playlist.playlist)),
        playlistDate: Value(playlist.playlist.date),
        recommendationsJson: jsonEncode(
          playlist.recommendations
              .map(_listenBrainzRecommendationToCacheJson)
              .toList(growable: false),
        ),
        matchedCount: Value(playlist.matchedCount),
        totalCount: Value(playlist.totalCount),
        // When the server was last searched for these tracks; local-only
        // passes keep it, so the daily recheck is not postponed.
        fetchedAt: playlist.searchedAt ?? DateTime.now(),
      ),
    );
  }
}

ListenBrainzDiscoverPlaylist? _listenBrainzDiscoverPlaylistFromCache(
  ListenBrainzWeeklyCacheTableData row,
) {
  try {
    final decoded = jsonDecode(row.recommendationsJson);
    if (decoded is! List) {
      return null;
    }
    final recommendations = decoded
        .whereType<Map<Object?, Object?>>()
        .map((json) {
          return _listenBrainzRecommendationFromCacheJson(
            Map<String, dynamic>.from(json),
          );
        })
        .whereType<ListenBrainzResolvedRecommendation>()
        .toList(growable: false);
    if (recommendations.isEmpty) {
      return null;
    }
    return ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: row.playlistIdentifier,
        title: row.title,
        date: row.playlistDate,
        sourcePatch: row.sourcePatch,
        tracks: recommendations
            .map((recommendation) => recommendation.track)
            .toList(growable: false),
      ),
      recommendations: recommendations,
      matchingComplete: true,
      searchedAt: row.fetchedAt,
    );
  } on Object catch (error) {
    AppLogger.debug(
      'ListenBrainz discover ignored corrupt weekly cache: '
      'sourcePatch="${row.sourcePatch}" error=$error.',
    );
    return null;
  }
}

Map<String, dynamic> _listenBrainzRecommendationToCacheJson(
  ListenBrainzResolvedRecommendation recommendation,
) {
  return <String, dynamic>{
    'track': _listenBrainzTrackToCacheJson(recommendation.track),
    'status': recommendation.status.name,
    'song': recommendation.song?.toJson(),
  };
}

ListenBrainzResolvedRecommendation? _listenBrainzRecommendationFromCacheJson(
  Map<String, dynamic> json,
) {
  final trackJson = json['track'];
  if (trackJson is! Map) {
    return null;
  }
  final track = _listenBrainzTrackFromCacheJson(
    Map<String, dynamic>.from(trackJson),
  );
  if (track == null) {
    return null;
  }
  final statusName = json['status'] as String?;
  final status = ListenBrainzRecommendationMatchStatus.values
      .where((value) => value.name == statusName)
      .firstOrNull;
  if (status == null) {
    return null;
  }
  final songJson = json['song'];
  final song = songJson is Map
      ? Song.fromJson(Map<String, dynamic>.from(songJson))
      : null;
  return ListenBrainzResolvedRecommendation(
    track: track,
    status:
        song == null && status == ListenBrainzRecommendationMatchStatus.matched
        ? ListenBrainzRecommendationMatchStatus.unmatched
        : status,
    song: song,
  );
}

Map<String, dynamic> _listenBrainzTrackToCacheJson(
  ListenBrainzPlaylistTrack track,
) {
  return <String, dynamic>{
    'title': track.title,
    'creator': track.creator,
    'album': track.album,
    'durationMs': track.durationMs,
    'identifiers': track.identifiers,
    'recordingMbid': track.recordingMbid,
    'recordingMsid': track.recordingMsid,
    'image': track.image,
  };
}

ListenBrainzPlaylistTrack? _listenBrainzTrackFromCacheJson(
  Map<String, dynamic> json,
) {
  final title = json['title'] as String?;
  if (title == null || title.trim().isEmpty) {
    return null;
  }
  return ListenBrainzPlaylistTrack(
    title: title,
    creator: json['creator'] as String?,
    album: json['album'] as String?,
    durationMs: (json['durationMs'] as num?)?.toInt(),
    identifiers:
        (json['identifiers'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const <String>[],
    recordingMbid: json['recordingMbid'] as String?,
    recordingMsid: json['recordingMsid'] as String?,
    image: json['image'] as String?,
  );
}

String? _listenBrainzWeekMarker(ListenBrainzPlaylist playlist) {
  final date = playlist.date;
  if (date != null) {
    return date.toIso8601String();
  }
  final match = RegExp(
    'week of ([0-9]{4}-[0-9]{2}-[0-9]{2})',
    caseSensitive: false,
  ).firstMatch(playlist.title);
  return match?.group(1);
}

String _listenBrainzPlaylistVersionMarker(ListenBrainzPlaylist playlist) {
  final weekMarker = _listenBrainzWeekMarker(playlist)?.trim();
  if (weekMarker != null && weekMarker.isNotEmpty) {
    return weekMarker;
  }
  return playlist.title.trim();
}

bool _listenBrainzMetadataMatchesCachedPlaylists(
  List<ListenBrainzPlaylist> metadata,
  List<ListenBrainzDiscoverPlaylist> cached,
) {
  if (metadata.length != cached.length) {
    return false;
  }
  final cachedBySourcePatch = <String, ListenBrainzDiscoverPlaylist>{};
  for (final playlist in cached) {
    final sourcePatch = playlist.playlist.sourcePatch?.trim();
    if (sourcePatch == null || sourcePatch.isEmpty) {
      return false;
    }
    cachedBySourcePatch[sourcePatch] = playlist;
  }
  for (final playlist in metadata) {
    final sourcePatch = playlist.sourcePatch?.trim();
    if (sourcePatch == null || sourcePatch.isEmpty) {
      return false;
    }
    final cachedPlaylist = cachedBySourcePatch[sourcePatch]?.playlist;
    if (cachedPlaylist == null) {
      return false;
    }
    if (cachedPlaylist.identifier != playlist.identifier) {
      return false;
    }
    if (_listenBrainzPlaylistVersionMarker(cachedPlaylist) !=
        _listenBrainzPlaylistVersionMarker(playlist)) {
      return false;
    }
  }
  return true;
}

bool _listenBrainzRecommendationNeedsResolution(
  ListenBrainzResolvedRecommendation recommendation,
) {
  return !recommendation.isPlayable;
}

/// A playable match that only a remote catalog (Octo-Fiesta) provides.
bool _listenBrainzIsRemoteMatch(
  ListenBrainzResolvedRecommendation recommendation,
) {
  final song = recommendation.song;
  return recommendation.isPlayable &&
      song != null &&
      !isServerAddressableSongId(song.id);
}

/// Recommendations the local pass checks: every one without a song on the
/// server.
int _listenBrainzLocalRecheckCount(
  List<ListenBrainzDiscoverPlaylist> playlists,
) {
  return playlists.fold<int>(0, (sum, playlist) {
    return sum +
        playlist.recommendations
            .where((recommendation) => !recommendation.hasServerSong)
            .length;
  });
}

/// The server is searched again for remote and unmatched tracks once a day.
const Duration _listenBrainzSearchRecheckInterval = Duration(hours: 24);

bool _listenBrainzSearchRecheckDue(
  List<ListenBrainzDiscoverPlaylist> playlists,
  DateTime now,
) {
  return playlists.any((playlist) {
    final searchedAt = playlist.searchedAt;
    return searchedAt == null ||
        now.difference(searchedAt) >= _listenBrainzSearchRecheckInterval;
  });
}

int _listenBrainzMatchedRecommendationCount(
  List<ListenBrainzDiscoverPlaylist> playlists,
) {
  return playlists.fold<int>(0, (sum, playlist) {
    return sum +
        playlist.recommendations.where((recommendation) {
          return recommendation.isPlayable;
        }).length;
  });
}

List<ListenBrainzDiscoverPlaylist> _visibleListenBrainzDiscoverPlaylists(
  List<ListenBrainzDiscoverPlaylist> playlists,
) {
  return playlists
      .where((playlist) => playlist.totalCount > 0)
      .toList(growable: false);
}

List<ListenBrainzDiscoverPlaylist>? _replaceListenBrainzPlaylist(
  List<ListenBrainzDiscoverPlaylist>? playlists,
  ListenBrainzDiscoverPlaylist replacement,
) {
  final sourcePatch = replacement.playlist.sourcePatch?.trim();
  if (sourcePatch == null || sourcePatch.isEmpty) {
    return playlists;
  }
  final updated = (playlists ?? const <ListenBrainzDiscoverPlaylist>[]).toList(
    growable: true,
  );
  final index = updated.indexWhere(
    (playlist) => playlist.playlist.sourcePatch?.trim() == sourcePatch,
  );
  if (index < 0) {
    updated.add(replacement);
  } else {
    updated[index] = replacement;
  }
  return _visibleListenBrainzDiscoverPlaylists(updated);
}

List<ListenBrainzPlaylist> _selectListenBrainzShowcaseMetadata(
  Iterable<ListenBrainzPlaylist> playlists,
) {
  final bySourcePatch = <String, ListenBrainzPlaylist>{};
  for (final playlist in playlists) {
    final sourcePatch = playlist.sourcePatch?.trim();
    if (sourcePatch == null || sourcePatch.isEmpty) {
      continue;
    }
    if (!bySourcePatch.containsKey(sourcePatch)) {
      bySourcePatch[sourcePatch] = playlist;
    }
  }
  return _listenBrainzShowcaseSourcePatches
      .map((sourcePatch) => bySourcePatch[sourcePatch])
      .whereType<ListenBrainzPlaylist>()
      .toList(growable: false);
}

Future<List<HomeRandomShowcaseAlbum>> _buildLikedDiscoveryAlbums({
  required SubsonicApiClient api,
  required List<SongsTableData> likedSongs,
  required Map<String, AlbumsTableData> scopedById,
  required int shuffleSeed,
}) async {
  final likedAlbumIds = likedSongs
      .map((song) => song.albumId?.trim())
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet();
  if (likedAlbumIds.isEmpty) {
    return const <HomeRandomShowcaseAlbum>[];
  }

  final seedPool = likedSongs.toList(growable: true);
  seedPool.shuffle(Random(shuffleSeed ^ 0x1f123bb5));
  final seedSongs = seedPool
      .where((song) => song.id.trim().isNotEmpty)
      .take(_homeRandomDiscoverySeedCount)
      .toList(growable: false);
  if (seedSongs.isEmpty) {
    return const <HomeRandomShowcaseAlbum>[];
  }

  final unseenCandidates = <String, HomeRandomShowcaseAlbum>{};
  final knownCandidates = <String, HomeRandomShowcaseAlbum>{};
  final similarSongResults = await Future.wait(
    seedSongs.map(
      (seed) =>
          _fetchHomeRandomDiscoverySimilarSongs(api: api, seedSongId: seed.id),
    ),
  );

  for (final similarSongs in similarSongResults) {
    if (similarSongs.isEmpty) {
      continue;
    }

    for (final song in similarSongs) {
      final albumId = song.albumId?.trim();
      if (albumId == null || albumId.isEmpty) {
        continue;
      }
      if (unseenCandidates.containsKey(albumId) ||
          knownCandidates.containsKey(albumId)) {
        continue;
      }

      final scopedAlbum = scopedById[albumId];
      final showcaseAlbum = scopedAlbum != null
          ? HomeRandomShowcaseAlbum.fromLocalDiscovery(scopedAlbum)
          : HomeRandomShowcaseAlbum.fromSimilarSong(song);
      if (likedAlbumIds.contains(albumId)) {
        knownCandidates[albumId] = showcaseAlbum;
      } else {
        unseenCandidates[albumId] = showcaseAlbum;
      }
    }
  }

  return <HomeRandomShowcaseAlbum>[
    ...unseenCandidates.values,
    ...knownCandidates.values,
  ];
}

Future<List<Song>> _fetchHomeRandomDiscoverySimilarSongs({
  required SubsonicApiClient api,
  required String seedSongId,
}) async {
  final cancelToken = CancelToken();
  try {
    return await api
        .getSimilarSongs(
          seedSongId,
          count: _homeRandomDiscoverySongCountPerSeed,
          cancelToken: cancelToken,
        )
        .timeout(
          _homeRandomDiscoverySimilarSongTimeout,
          onTimeout: () {
            cancelToken.cancel('Home liked-song discovery timed out');
            throw TimeoutException(
              'Home liked-song discovery timed out for seed $seedSongId',
              _homeRandomDiscoverySimilarSongTimeout,
            );
          },
        );
  } on TimeoutException {
    AppLogger.debug(
      'Home liked-song discovery seed skipped after '
      '${_homeRandomDiscoverySimilarSongTimeout.inMilliseconds}ms.',
    );
    return const <Song>[];
  } on DioException catch (error) {
    if (!CancelToken.isCancel(error)) {
      AppLogger.debug(
        'Home liked-song discovery seed skipped: '
        '${error.response?.statusCode ?? error.type.name}.',
      );
    }
    return const <Song>[];
  } on Exception {
    return const <Song>[];
  }
}

final homeDownloadedMostPlayedSongsProvider =
    StreamProvider<List<SongsTableData>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final downloadedSongIds =
          ref.watch(downloadedSongIdsProvider).asData?.value ??
          const <String>{};
      return dao
          .watchMostPlayedSongs(limit: null)
          .map(
            (songs) => songs
                .where((song) => downloadedSongIds.contains(song.id))
                .take(5)
                .toList(growable: false),
          );
    });

// ---------------------------------------------------------------------------
// Kept for backwards compat / possible future use — can be removed later.
// ---------------------------------------------------------------------------

final homeRecentlyPlayedProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).historyDao;
  return dao.watchRecentlyPlayedSongs(limit: 20);
});

final homeFrequentAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Album>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return await api.getAlbumList2(
    type: 'frequent',
    size: 20,
    cancelToken: cancelToken,
  );
});

/// ListenBrainz names its weekly playlists in English; show Navis's own
/// localized names for the ones it recognises.
String localizedWeeklyPlaylistTitle(
  AppLocalizations l10n, {
  required String? sourcePatch,
  required String fallback,
}) => switch (sourcePatch) {
  'weekly-jams' => l10n.weeklyPlaylistJamsTitle,
  'weekly-exploration' => l10n.weeklyPlaylistExplorationTitle,
  _ => fallback,
};
