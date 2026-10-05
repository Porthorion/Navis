import 'package:drift/drift.dart';

import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/catalog_source.dart';

/// Stores [songs] that a server search returned as provisional library rows,
/// with their artists and albums, so the next local match finds them and
/// song menus and pages can open them before the next library sync.
///
/// Rows a sync already wrote stay as they are. [recordingMbidsBySongId]
/// adds a recording MBID the search result lacks. The ListenBrainz weekly
/// playlists and the ranked top-song lists (an artist's top songs, Home's
/// Trending Now) store the server copies they match this way.
Future<void> persistProvisionalSearchSongs(
  LibraryDao dao,
  Iterable<Song> songs, {
  Map<String, String> recordingMbidsBySongId = const <String, String>{},
}) async {
  final songsById = <String, Song>{for (final song in songs) song.id: song};
  if (songsById.isEmpty) return;

  final artistsById = <String, ArtistsTableCompanion>{};
  final albumsById = <String, AlbumsTableCompanion>{};
  final songRows = <SongsTableCompanion>[];
  for (final song in songsById.values) {
    final isExternal = isExternalCatalogSource(
      id: song.id,
      apiIsExternal: song.isExternal,
    );
    final artistId = song.artistId?.trim();
    if (artistId != null && artistId.isNotEmpty) {
      artistsById[artistId] = ArtistsTableCompanion.insert(
        id: artistId,
        name: (song.artist?.trim().isNotEmpty ?? false)
            ? song.artist!.trim()
            : artistId,
        coverArt: Value(song.coverArt),
        isExternal: Value(isExternal),
      );
    }

    final albumId = song.albumId?.trim();
    if (albumId != null && albumId.isNotEmpty) {
      albumsById[albumId] = AlbumsTableCompanion.insert(
        id: albumId,
        name: (song.album?.trim().isNotEmpty ?? false)
            ? song.album!.trim()
            : albumId,
        artistId: Value(artistId == null || artistId.isEmpty ? null : artistId),
        artistName: Value(song.artist),
        songCount: const Value(1),
        duration: Value(song.duration),
        coverArt: Value(song.coverArt),
        isExternal: Value(isExternal),
      );
    }

    songRows.add(
      _provisionalSongCompanion(
        song,
        recordingMbid: recordingMbidsBySongId[song.id],
      ),
    );
  }

  await dao.upsertProvisionalArtists(
    artistsById.values.toList(growable: false),
  );
  await dao.upsertProvisionalAlbums(albumsById.values.toList(growable: false));
  await dao.upsertProvisionalSongs(songRows);
}

/// [song] as the library row [persistProvisionalSearchSongs] writes for it.
SongsTableData provisionalSongTableData(Song song) {
  return SongsTableData(
    isProvisional: false,
    isExternal: isExternalCatalogSource(
      id: song.id,
      apiIsExternal: song.isExternal,
    ),
    id: song.id,
    title: song.title,
    albumId: song.albumId,
    artistId: song.artistId,
    artistName: song.artist,
    albumName: song.album,
    track: song.track,
    discNumber: song.discNumber,
    duration: song.duration,
    bitRate: song.bitRate,
    sampleRate: song.sampleRate,
    contentType: song.contentType,
    suffix: song.suffix,
    size: song.size,
    coverArt: song.coverArt,
    starred: song.starred,
    userRating: song.userRating,
    playCount: song.playCount,
    createdAt: song.created,
    replayGainTrackGain: song.replayGain?.trackGain,
    replayGainAlbumGain: song.replayGain?.albumGain,
    replayGainTrackPeak: song.replayGain?.trackPeak,
    replayGainAlbumPeak: song.replayGain?.albumPeak,
  );
}

SongsTableCompanion _provisionalSongCompanion(
  Song song, {
  String? recordingMbid,
}) {
  return SongsTableCompanion.insert(
    id: song.id,
    title: song.title,
    albumId: Value(song.albumId),
    artistId: Value(song.artistId),
    artistName: Value(song.artist),
    albumName: Value(song.album),
    track: Value(song.track),
    discNumber: Value(song.discNumber),
    duration: Value(song.duration),
    bitRate: Value(song.bitRate),
    sampleRate: Value(song.sampleRate),
    contentType: Value(song.contentType),
    suffix: Value(song.suffix),
    size: Value(song.size),
    coverArt: Value(song.coverArt),
    starred: Value(song.starred),
    recordingMbid: Value(recordingMbid ?? song.musicBrainzId),
    userRating: Value(song.userRating),
    playCount: Value(song.playCount),
    createdAt: Value(song.created),
    replayGainTrackGain: Value(song.replayGain?.trackGain),
    replayGainAlbumGain: Value(song.replayGain?.albumGain),
    replayGainTrackPeak: Value(song.replayGain?.trackPeak),
    replayGainAlbumPeak: Value(song.replayGain?.albumPeak),
    isExternal: Value(
      isExternalCatalogSource(id: song.id, apiIsExternal: song.isExternal),
    ),
  );
}
