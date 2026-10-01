import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/api/models/album.dart';

part 'artist.freezed.dart';
part 'artist.g.dart';

@freezed
abstract class Artist with _$Artist {
  const factory({
    required String id,
    required String name,
    int? albumCount,
    String? coverArt,
    DateTime? starred,
    bool? isExternal,

    /// OpenSubsonic extension: MusicBrainz artist ID.
    /// Absent on standard Subsonic responses.
    String? musicBrainzId,
    @Default(<Album>[]) List<Album> albums,
  }) = _Artist;

  factory fromJson(Map<String, dynamic> json) => _$ArtistFromJson(json);
}
