import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';

typedef DownloadArtworkGap = ({
  String? albumId,
  String? coverArt,
  String name,
  String artist,
});

/// Missing metadata for retained downloads; artwork presence comes from disk.
class DownloadMetadataGaps {
  const new({
    required this.songsMissingLyrics,
    required this.albumsMissingArtwork,
    required this.totalSongs,
    required this.totalAlbums,
  });

  final List<DownloadMetadataGap> songsMissingLyrics;
  final List<DownloadArtworkGap> albumsMissingArtwork;
  final int totalSongs;
  final int totalAlbums;

  /// Reads permanent downloads and checks each unique cover once on disk.
  static Future<DownloadMetadataGaps> load(
    CacheDao dao,
    PermanentArtworkStore store,
  ) async {
    final songs = await dao.getPermanentDownloadMetadata();
    final covers = <String, bool>{};
    final albums = <(String?, String?, String?, String?), DownloadArtworkGap>{};
    for (final song in songs) {
      final id = song.coverArt?.trim();
      final cover = id == null || id.isEmpty ? null : id;
      if (cover != null && !covers.containsKey(cover)) {
        covers[cover] = await store.fileFor(cover) != null;
      }
      final key = (
        song.albumId,
        cover,
        song.albumId == null ? song.album : null,
        song.albumId == null ? song.artist : null,
      );
      albums.putIfAbsent(
        key,
        () => (
          albumId: song.albumId,
          coverArt: cover,
          name: song.album?.trim().isNotEmpty == true
              ? song.album!
              : song.title,
          artist: song.artist ?? '',
        ),
      );
    }
    return DownloadMetadataGaps(
      songsMissingLyrics: List.unmodifiable(
        songs.where(
          (song) =>
              !song.hasSyncedLyrics &&
              !song.hasPlainLyrics &&
              song.lyricsCache?.instrumental != true,
        ),
      ),
      albumsMissingArtwork: List.unmodifiable(
        albums.values.where(
          (album) => album.coverArt == null || covers[album.coverArt] != true,
        ),
      ),
      totalSongs: songs.length,
      totalAlbums: albums.length,
    );
  }
}
