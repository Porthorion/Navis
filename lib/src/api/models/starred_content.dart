import 'package:navis/src/api/models/album.dart';
import 'package:navis/src/api/models/artist.dart';
import 'package:navis/src/api/models/song.dart';

class StarredContent {
  const StarredContent({
    this.albums = const <Album>[],
    this.artists = const <Artist>[],
    this.songs = const <Song>[],
  });

  final List<Album> albums;
  final List<Artist> artists;
  final List<Song> songs;
}
