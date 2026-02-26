import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/api/models/song.dart';

part 'album.freezed.dart';
part 'album.g.dart';

@freezed
abstract class Album with _$Album {
  const factory Album({
    required String id,
    required String name,
    String? artist,
    String? artistId,
    int? songCount,
    int? duration,
    int? year,
    String? genre,
    String? coverArt,
    DateTime? starred,
    int? playCount,

    /// When the album was added to the Subsonic server library.
    /// Maps to the `created` field in the Subsonic API response.
    DateTime? created,
    @Default(<Song>[]) List<Song> songs,
  }) = _Album;

  factory Album.fromJson(Map<String, dynamic> json) => _$AlbumFromJson(json);
}
