import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/domain/home_section_ids.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart' show isDesktopRuntime;
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';

const int _homeWarmupTargetLimit = 6;
const int _homeWarmupDecodeLimit = 3;

/// One exact cover-art variant that an initial Home surface will request.
@immutable
class HomeArtworkWarmupTarget {
  const new({required this.coverArtId, required this.size});

  final String coverArtId;
  final int size;
}

/// Aggregate, non-persistent warm-up state for diagnostics and lifecycle
/// verification. It never exposes artwork identifiers outside the app.
class HomeOnboardingWarmupTracker {
  final Set<String> _targetCacheKeys = <String>{};
  final Set<String> _readyCacheKeys = <String>{};

  HomeOnboardingWarmupStatus get status => HomeOnboardingWarmupStatus(
    targetCount: _targetCacheKeys.length,
    readyCount: _readyCacheKeys.length,
  );

  void recordTargets(Iterable<HomeArtworkWarmupTarget> targets) {
    _targetCacheKeys
      ..clear()
      ..addAll(targets.map(_targetCacheKey));
    _readyCacheKeys.clear();
  }

  void recordReady(HomeArtworkWarmupTarget target) {
    final key = _targetCacheKey(target);
    if (_targetCacheKeys.contains(key)) {
      _readyCacheKeys.add(key);
    }
  }
}

@immutable
class HomeOnboardingWarmupStatus {
  const new({required this.targetCount, required this.readyCount});

  final int targetCount;
  final int readyCount;
}

String _targetCacheKey(HomeArtworkWarmupTarget target) {
  return coverArtImageCacheKey(target.coverArtId, target.size);
}

/// A session-only handle for Home artwork work started during onboarding.
class HomeOnboardingWarmupSession {
  new _(this._run, this.done);

  final _HomeOnboardingWarmupRun _run;
  final Future<void> done;

  void stop() {
    _run.isActive = false;
  }
}

class _HomeOnboardingWarmupRun {
  bool isActive = true;
}

/// Performs a deliberately small Home artwork warm-up while onboarding is on
/// screen. It owns no durable work: leaving onboarding simply stops scheduling
/// any remaining targets.
class HomeOnboardingWarmup {
  new({
    required this._resolveTargets,
    required this._warmTarget,
    required this._isOnline,
    this._onArtworkWarmed,
  });

  final Future<List<HomeArtworkWarmupTarget>> Function() _resolveTargets;
  final Future<void> Function(HomeArtworkWarmupTarget target) _warmTarget;
  final bool Function() _isOnline;
  final void Function(HomeArtworkWarmupTarget target)? _onArtworkWarmed;

  HomeOnboardingWarmupSession start({
    Future<void> Function(HomeArtworkWarmupTarget target)? onArtworkReady,
  }) {
    final run = _HomeOnboardingWarmupRun();
    return HomeOnboardingWarmupSession._(
      run,
      _run(run, onArtworkReady: onArtworkReady),
    );
  }

  Future<void> _run(
    _HomeOnboardingWarmupRun run, {
    Future<void> Function(HomeArtworkWarmupTarget target)? onArtworkReady,
  }) async {
    if (!_isOnline()) {
      return;
    }

    List<HomeArtworkWarmupTarget> targets;
    try {
      targets = await _resolveTargets();
    } on Object {
      return;
    }

    var decoded = 0;
    for (final target in targets) {
      if (!run.isActive || !_isOnline()) {
        return;
      }
      try {
        await _warmTarget(target);
      } on Object {
        // This is opportunistic UI work. The corresponding Home card keeps
        // its normal cache/network fallback if a warm-up request fails.
        continue;
      }
      _onArtworkWarmed?.call(target);
      if (!run.isActive || !_isOnline() || onArtworkReady == null) {
        continue;
      }
      if (decoded >= _homeWarmupDecodeLimit) {
        continue;
      }
      decoded += 1;
      try {
        await onArtworkReady(target);
      } on Object {
        // A decoded-memory cache miss must never interfere with onboarding.
      }
    }
  }
}

final homeOnboardingWarmupTrackerProvider =
    Provider<HomeOnboardingWarmupTracker>(
      (ref) => HomeOnboardingWarmupTracker(),
    );

final homeOnboardingWarmupProvider = Provider<HomeOnboardingWarmup>((ref) {
  final tracker = ref.read(homeOnboardingWarmupTrackerProvider);
  return HomeOnboardingWarmup(
    resolveTargets: () async {
      final targets = await resolveHomeOnboardingWarmupTargets(
        ref,
        desktopRuntime: isDesktopRuntime,
      );
      tracker.recordTargets(targets);
      return targets;
    },
    warmTarget: (target) => _warmHomeArtworkTarget(ref, target),
    isOnline: () => ref.read(networkTypeProvider) != NetworkType.offline,
    onArtworkWarmed: tracker.recordReady,
  );
});

/// Starts the session-only warm-up after Onboarding has painted its first
/// frame. The caller owns the returned handle and stops it on exit/background.
HomeOnboardingWarmupSession startHomeOnboardingWarmup(
  WidgetRef ref,
  BuildContext context,
) {
  return ref
      .read(homeOnboardingWarmupProvider)
      .start(
        onArtworkReady: (target) =>
            _decodeHomeArtworkTarget(ref, context, target),
      );
}

@visibleForTesting
List<HomeArtworkWarmupTarget> selectHomeArtworkWarmupTargets({
  required Iterable<String> sectionOrder,
  required Set<String> hiddenSections,
  required Map<String, List<HomeArtworkWarmupTarget>> targetsBySection,
  int maxTargets = _homeWarmupTargetLimit,
}) {
  assert(maxTargets > 0, 'maxTargets must be positive');
  final selected = <HomeArtworkWarmupTarget>[];
  final seenCoverArtIds = <String>{};
  for (final sectionId in sectionOrder) {
    if (hiddenSections.contains(sectionId)) {
      continue;
    }
    for (final target
        in targetsBySection[sectionId] ?? const <HomeArtworkWarmupTarget>[]) {
      final id = target.coverArtId.trim();
      if (id.isEmpty || !seenCoverArtIds.add(id)) {
        continue;
      }
      selected.add(HomeArtworkWarmupTarget(coverArtId: id, size: target.size));
      if (selected.length == maxTargets) {
        return selected;
      }
    }
  }
  return selected;
}

Future<List<HomeArtworkWarmupTarget>> resolveHomeOnboardingWarmupTargets(
  Ref ref, {
  required bool desktopRuntime,
}) async {
  final persistedOrder = ref.read(homeSectionOrderProvider);
  final sectionOrder = HomeSectionIds.resolveOrder(persistedOrder);
  final hiddenSections = HomeSectionIds.resolveHidden(
    ref.read(homeSectionsHiddenProvider),
    persistedOrder: persistedOrder,
  );
  final downloadedOnly = ref.read(downloadedOnlyFilterProvider);
  final likedOnly = ref.read(homeLikedOnlyFilterProvider);
  final selected = <HomeArtworkWarmupTarget>[];
  final seenCoverArtIds = <String>{};

  for (final sectionId in sectionOrder) {
    if (hiddenSections.contains(sectionId)) {
      continue;
    }
    List<HomeArtworkWarmupTarget> candidates;
    try {
      candidates = await _targetsForHomeSection(
        ref,
        sectionId: sectionId,
        downloadedOnly: downloadedOnly,
        likedOnly: likedOnly,
        desktopRuntime: desktopRuntime,
      );
    } on Object {
      // Each Home section remains independently optional. A transient failure
      // in one provider must not prevent later local sections from warming.
      continue;
    }
    for (final target in candidates) {
      final id = target.coverArtId.trim();
      if (id.isEmpty || !seenCoverArtIds.add(id)) {
        continue;
      }
      selected.add(HomeArtworkWarmupTarget(coverArtId: id, size: target.size));
      if (selected.length == _homeWarmupTargetLimit) {
        return selected;
      }
    }
  }
  return selected;
}

Future<List<HomeArtworkWarmupTarget>> _targetsForHomeSection(
  Ref ref, {
  required String sectionId,
  required bool downloadedOnly,
  required bool likedOnly,
  required bool desktopRuntime,
}) async {
  switch (sectionId) {
    case HomeSectionIds.randomAlbums:
      if (downloadedOnly) {
        final albums = await ref.read(
          homeDownloadedRandomAlbumsProvider.future,
        );
        return _randomLocalAlbumTargets(_filterLikedAlbums(albums, likedOnly));
      }
      final albums = await ref.read(homeRandomAlbumsProvider.future);
      // Home's regular random fallback is intentionally used rather than its
      // ListenBrainz-enhanced showcase. The latter starts external discovery,
      // which must never be triggered from onboarding warm-up.
      return _randomServerAlbumTargets(
        _filterLikedServerAlbums(albums, likedOnly),
      );
    case HomeSectionIds.recentlyLikedAlbums:
      final albums = await ref.read(likedAlbumsRecentProvider.future);
      if (!downloadedOnly) {
        return _localAlbumTargets(albums);
      }
      final downloadedIds = (await ref.read(
        downloadedContentIdsProvider.future,
      )).albumIds;
      return _localAlbumTargets(
        albums.where((album) => downloadedIds.contains(album.id)),
      );
    case HomeSectionIds.likedTracks:
      final songs = downloadedOnly
          ? await ref.read(homeDownloadedLikedSongsProvider.future)
          : await ref.read(homeLikedSongsProvider.future);
      return _songTargets(songs, desktopRuntime: desktopRuntime);
    case HomeSectionIds.recentlyAdded:
      if (downloadedOnly) {
        final albums = await ref.read(
          homeDownloadedRecentlyAddedAlbumsProvider.future,
        );
        return _localAlbumTargets(_filterLikedAlbums(albums, likedOnly));
      }
      final albums = await ref.read(homeRecentlyAddedProvider.future);
      return _serverAlbumTargets(_filterLikedServerAlbums(albums, likedOnly));
    case HomeSectionIds.recentlyPlayed:
      final albums = downloadedOnly
          ? await ref.read(homeDownloadedRecentlyPlayedAlbumsProvider.future)
          : await ref.read(homeRecentlyPlayedAlbumsProvider.future);
      return _localAlbumTargets(_filterLikedAlbums(albums, likedOnly));
    case HomeSectionIds.mostPlayed:
      final songs = downloadedOnly
          ? await ref.read(homeDownloadedMostPlayedSongsProvider.future)
          : await ref.read(homeMostPlayedSongsProvider.future);
      return _songTargets(
        likedOnly ? songs.where((song) => song.starred != null) : songs,
        desktopRuntime: desktopRuntime,
      );
    case HomeSectionIds.recentlyPlayedTracks:
      var songs = await ref.read(homeRecentlyPlayedProvider.future);
      if (downloadedOnly) {
        final downloadedSongIds = await ref.read(
          downloadedSongIdsProvider.future,
        );
        songs = songs
            .where((song) => downloadedSongIds.contains(song.id))
            .toList(growable: false);
      }
      return _songTargets(
        likedOnly ? songs.where((song) => song.starred != null) : songs,
        desktopRuntime: desktopRuntime,
      );
    case HomeSectionIds.frequentAlbums:
      if (downloadedOnly) {
        return const <HomeArtworkWarmupTarget>[];
      }
      final albums = await ref.read(homeFrequentAlbumsProvider.future);
      return _serverAlbumTargets(_filterLikedServerAlbums(albums, likedOnly));
    case HomeSectionIds.quickActions:
      return const <HomeArtworkWarmupTarget>[];
  }
  return const <HomeArtworkWarmupTarget>[];
}

Iterable<AlbumsTableData> _filterLikedAlbums(
  Iterable<AlbumsTableData> albums,
  bool likedOnly,
) {
  return likedOnly ? albums.where((album) => album.starred != null) : albums;
}

Iterable<Album> _filterLikedServerAlbums(
  Iterable<Album> albums,
  bool likedOnly,
) {
  return likedOnly ? albums.where((album) => album.starred != null) : albums;
}

List<HomeArtworkWarmupTarget> _localAlbumTargets(
  Iterable<AlbumsTableData> albums, {
  int size = kCoverArtStandardSize,
}) {
  return albums
      .where((album) => !album.isExternal)
      .map(
        (album) => HomeArtworkWarmupTarget(
          coverArtId: album.coverArt ?? '',
          size: size,
        ),
      )
      .toList(growable: false);
}

/// The first random album is the large visible hero. The small selector strip
/// is intentionally left to normal visible-priority loading so the remaining
/// limited targets can cover the next full-size Home section.
List<HomeArtworkWarmupTarget> _randomLocalAlbumTargets(
  Iterable<AlbumsTableData> albums,
) {
  for (final album in albums) {
    if (album.isExternal) {
      continue;
    }
    final coverArtId = album.coverArt?.trim() ?? '';
    if (coverArtId.isEmpty) {
      continue;
    }
    return <HomeArtworkWarmupTarget>[
      HomeArtworkWarmupTarget(
        coverArtId: coverArtId,
        size: kCoverArtStandardSize,
      ),
    ];
  }
  return const <HomeArtworkWarmupTarget>[];
}

List<HomeArtworkWarmupTarget> _serverAlbumTargets(
  Iterable<Album> albums, {
  int size = kCoverArtStandardSize,
}) {
  return albums
      .where((album) => album.isExternal != true)
      .map(
        (album) => HomeArtworkWarmupTarget(
          coverArtId: album.coverArt ?? '',
          size: size,
        ),
      )
      .toList(growable: false);
}

List<HomeArtworkWarmupTarget> _randomServerAlbumTargets(
  Iterable<Album> albums,
) {
  for (final album in albums) {
    if (album.isExternal == true) {
      continue;
    }
    final coverArtId = album.coverArt?.trim() ?? '';
    if (coverArtId.isEmpty) {
      continue;
    }
    return <HomeArtworkWarmupTarget>[
      HomeArtworkWarmupTarget(
        coverArtId: coverArtId,
        size: kCoverArtStandardSize,
      ),
    ];
  }
  return const <HomeArtworkWarmupTarget>[];
}

List<HomeArtworkWarmupTarget> _songTargets(
  Iterable<SongsTableData> songs, {
  required bool desktopRuntime,
}) {
  final size = desktopRuntime ? 128 : 160;
  return songs
      .where((song) => !song.isExternal)
      .map(
        (song) => HomeArtworkWarmupTarget(
          coverArtId: song.coverArt ?? '',
          size: size,
        ),
      )
      .toList(growable: false);
}

Future<void> _warmHomeArtworkTarget(
  Ref ref,
  HomeArtworkWarmupTarget target,
) async {
  final api = ref.read(subsonicApiProvider);
  if (api == null) {
    return;
  }
  final cacheManager = ref.read(coverArtCacheManagerProvider);
  final cacheKey = coverArtImageCacheKey(target.coverArtId, target.size);
  if (await cacheManager.getFileFromCache(cacheKey) != null) {
    return;
  }
  final url = api
      .getCoverArtUrl(id: target.coverArtId, size: target.size)
      .toString();
  // No visible/critical load interest is registered for this cache request,
  // so the shared file service schedules it at background priority.
  await cacheManager.downloadFile(url, key: cacheKey);
}

Future<void> _decodeHomeArtworkTarget(
  WidgetRef ref,
  BuildContext context,
  HomeArtworkWarmupTarget target,
) async {
  if (!context.mounted) {
    return;
  }
  final api = ref.read(subsonicApiProvider);
  if (api == null) {
    return;
  }
  final cacheManager = ref.read(coverArtCacheManagerProvider);
  final cacheKey = coverArtImageCacheKey(target.coverArtId, target.size);
  final provider = CachedNetworkImageProvider(
    api.getCoverArtUrl(id: target.coverArtId, size: target.size).toString(),
    cacheKey: cacheKey,
    cacheManager: cacheManager,
    maxWidth: target.size,
    maxHeight: target.size,
  );
  try {
    await precacheImage(provider, context);
  } on Object {
    AppLogger.debug('Home onboarding artwork decode skipped.');
  }
}
