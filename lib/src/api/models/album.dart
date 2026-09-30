import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:navis/src/api/models/song.dart';

part 'album.freezed.dart';
part 'album.g.dart';

@freezed
abstract class Album with _$Album {
  @JsonSerializable(explicitToJson: true)
  const factory Album({
    required String id,
    required String name,
    String? artist,
    String? artistId,

    /// OpenSubsonic extension: multiple album artists with individual IDs.
    /// Falls back to the legacy [artist]/[artistId] pair on standard Subsonic.
    @Default(<ArtistRef>[]) List<ArtistRef> artists,
    int? songCount,
    int? duration,
    int? year,
    String? coverArt,
    DateTime? starred,
    int? userRating,
    int? playCount,
    bool? isExternal,

    /// OpenSubsonic extension: MusicBrainz release ID for the album.
    /// Absent on standard Subsonic responses.
    String? musicBrainzId,

    /// When the album was added to the Subsonic server library.
    /// Maps to the `created` field in the Subsonic API response.
    DateTime? created,
    @Default(<Song>[]) List<Song> songs,
  }) = _Album;

  factory Album.fromJson(Map<String, dynamic> json) => _$AlbumFromJson(json);
}
