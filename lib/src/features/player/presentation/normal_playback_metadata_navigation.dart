import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';

enum NormalPlaybackMetadataDestinationType { artist, album, filteredSearch }

@immutable
class NormalPlaybackMetadataDestination {
  const NormalPlaybackMetadataDestination.artist(this.id)
    : type = NormalPlaybackMetadataDestinationType.artist,
      query = null,
      filter = null;

  const NormalPlaybackMetadataDestination.album(this.id)
    : type = NormalPlaybackMetadataDestinationType.album,
      query = null,
      filter = null;

  const NormalPlaybackMetadataDestination.filteredSearch(
    this.query,
    this.filter,
  ) : type = NormalPlaybackMetadataDestinationType.filteredSearch,
      id = null;

  final NormalPlaybackMetadataDestinationType type;
  final String? id;
  final String? query;
  final SearchResultType? filter;
}

@immutable
class NormalPlaybackMetadataContext {
  const NormalPlaybackMetadataContext({
    this.song,
    this.mediaItem,
    this.title,
    this.artistName,
    this.albumName,
    this.artistId,
    this.albumId,
  });

  final SongsTableData? song;
  final MediaItem? mediaItem;
  final String? title;
  final String? artistName;
  final String? albumName;
  final String? artistId;
  final String? albumId;
}

class NormalPlaybackMetadataNavigationResolver {
  const NormalPlaybackMetadataNavigationResolver(this._dao);

  final LibraryDao _dao;

  Future<NormalPlaybackMetadataDestination?> resolveArtist(
    NormalPlaybackMetadataContext context,
  ) async {
    final artistId = _firstNonEmpty([
      context.song?.artistId,
      context.artistId,
      _stringExtra(context.mediaItem, 'artistId'),
    ]);
    if (artistId != null && await _dao.getArtistById(artistId) != null) {
      return NormalPlaybackMetadataDestination.artist(artistId);
    }

    final artistName = _firstNonEmpty([
      context.song?.artistName,
      context.artistName,
      context.mediaItem?.artist,
    ]);
    if (artistName == null) {
      return null;
    }

    final match = await _dao.findOneExactNormalizedArtistByName(artistName);
    if (match != null) {
      return NormalPlaybackMetadataDestination.artist(match.id);
    }
    return NormalPlaybackMetadataDestination.filteredSearch(
      artistName,
      SearchResultType.artists,
    );
  }

  Future<NormalPlaybackMetadataDestination?> resolveAlbum(
    NormalPlaybackMetadataContext context,
  ) async {
    final albumId = _firstNonEmpty([
      context.song?.albumId,
      context.albumId,
      _stringExtra(context.mediaItem, 'albumId'),
    ]);
    if (albumId != null && await _dao.getAlbumById(albumId) != null) {
      return NormalPlaybackMetadataDestination.album(albumId);
    }

    final albumName = _firstNonEmpty([
      context.song?.albumName,
      context.albumName,
      context.mediaItem?.album,
    ]);
    if (albumName == null) {
      return null;
    }

    final match = await _dao.findOneExactNormalizedAlbumByName(
      albumName,
      artistId: _firstNonEmpty([
        context.song?.artistId,
        context.artistId,
        _stringExtra(context.mediaItem, 'artistId'),
      ]),
      artistName: _firstNonEmpty([
        context.song?.artistName,
        context.artistName,
        context.mediaItem?.artist,
      ]),
    );
    if (match != null) {
      return NormalPlaybackMetadataDestination.album(match.id);
    }
    return NormalPlaybackMetadataDestination.filteredSearch(
      albumName,
      SearchResultType.albums,
    );
  }

  Future<NormalPlaybackMetadataDestination?> resolveTitle(
    NormalPlaybackMetadataContext context,
  ) async {
    final currentAlbumId = _firstNonEmpty([
      context.song?.albumId,
      context.albumId,
      _stringExtra(context.mediaItem, 'albumId'),
    ]);
    if (currentAlbumId != null &&
        await _dao.getAlbumById(currentAlbumId) != null) {
      return NormalPlaybackMetadataDestination.album(currentAlbumId);
    }

    final title = _firstNonEmpty([
      context.song?.title,
      context.title,
      context.mediaItem?.title,
    ]);
    if (title == null) {
      return null;
    }

    final match = await _dao.findOneExactNormalizedSongByTitle(
      title,
      artistId: _firstNonEmpty([
        context.song?.artistId,
        context.artistId,
        _stringExtra(context.mediaItem, 'artistId'),
      ]),
      artistName: _firstNonEmpty([
        context.song?.artistName,
        context.artistName,
        context.mediaItem?.artist,
      ]),
      albumName: _firstNonEmpty([
        context.song?.albumName,
        context.albumName,
        context.mediaItem?.album,
      ]),
    );
    final matchedAlbumId = match?.albumId?.trim();
    if (matchedAlbumId != null &&
        matchedAlbumId.isNotEmpty &&
        await _dao.getAlbumById(matchedAlbumId) != null) {
      return NormalPlaybackMetadataDestination.album(matchedAlbumId);
    }

    return NormalPlaybackMetadataDestination.filteredSearch(
      title,
      SearchResultType.songs,
    );
  }

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return null;
  }

  static String? _stringExtra(MediaItem? mediaItem, String key) {
    final raw = mediaItem?.extras?[key];
    return raw is String ? raw : null;
  }
}

abstract final class NormalPlaybackMetadataNavigator {
  static Future<void> goToArtist(
    BuildContext context,
    WidgetRef ref, {
    SongsTableData? song,
    String? artistId,
    String? artistName,
  }) {
    return _resolveAndNavigate(
      context,
      ref,
      (resolver, metadata) => resolver.resolveArtist(
        metadata.copyWith(
          song: song,
          artistId: artistId,
          artistName: artistName,
        ),
      ),
    );
  }

  static Future<void> goToAlbum(
    BuildContext context,
    WidgetRef ref, {
    SongsTableData? song,
    String? albumId,
    String? albumName,
    String? artistId,
    String? artistName,
  }) {
    return _resolveAndNavigate(
      context,
      ref,
      (resolver, metadata) => resolver.resolveAlbum(
        metadata.copyWith(
          song: song,
          albumId: albumId,
          albumName: albumName,
          artistId: artistId,
          artistName: artistName,
        ),
      ),
    );
  }

  static Future<void> goToTitle(
    BuildContext context,
    WidgetRef ref, {
    SongsTableData? song,
    String? title,
    String? albumId,
    String? albumName,
    String? artistId,
    String? artistName,
  }) {
    return _resolveAndNavigate(
      context,
      ref,
      (resolver, metadata) => resolver.resolveTitle(
        metadata.copyWith(
          song: song,
          title: title,
          albumId: albumId,
          albumName: albumName,
          artistId: artistId,
          artistName: artistName,
        ),
      ),
    );
  }

  static Future<void> _resolveAndNavigate(
    BuildContext context,
    WidgetRef ref,
    Future<NormalPlaybackMetadataDestination?> Function(
      NormalPlaybackMetadataNavigationResolver resolver,
      NormalPlaybackMetadataContext metadata,
    )
    resolve,
  ) async {
    final mediaItem = ref.read(currentMediaItemProvider).asData?.value;
    final resolver = NormalPlaybackMetadataNavigationResolver(
      ref.read(navisDatabaseProvider).libraryDao,
    );
    final destination = await resolve(
      resolver,
      NormalPlaybackMetadataContext(mediaItem: mediaItem),
    );
    if (!context.mounted || destination == null) {
      return;
    }
    _navigate(context, ref, destination);
  }

  static void _navigate(
    BuildContext context,
    WidgetRef ref,
    NormalPlaybackMetadataDestination destination,
  ) {
    switch (destination.type) {
      case NormalPlaybackMetadataDestinationType.artist:
        NavService.goToArtist(context, ref, destination.id!);
      case NormalPlaybackMetadataDestinationType.album:
        NavService.goToAlbum(context, ref, destination.id!);
      case NormalPlaybackMetadataDestinationType.filteredSearch:
        NavService.goToFilteredSearch(
          context,
          ref,
          destination.query!,
          destination.filter!,
        );
    }
  }
}

extension on NormalPlaybackMetadataContext {
  NormalPlaybackMetadataContext copyWith({
    SongsTableData? song,
    String? title,
    String? artistName,
    String? albumName,
    String? artistId,
    String? albumId,
  }) {
    return NormalPlaybackMetadataContext(
      song: song ?? this.song,
      mediaItem: mediaItem,
      title: title ?? this.title,
      artistName: artistName ?? this.artistName,
      albumName: albumName ?? this.albumName,
      artistId: artistId ?? this.artistId,
      albumId: albumId ?? this.albumId,
    );
  }
}
