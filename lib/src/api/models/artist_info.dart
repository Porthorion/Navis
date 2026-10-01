import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/api/models/artist.dart';

part 'artist_info.freezed.dart';
part 'artist_info.g.dart';

@freezed
abstract class ArtistInfo with _$ArtistInfo {
  const factory({
    String? biography,
    String? musicBrainzId,
    String? lastFmUrl,
    String? smallImageUrl,
    String? mediumImageUrl,
    String? largeImageUrl,
    @Default(<Artist>[]) List<Artist> similarArtists,
  }) = _ArtistInfo;

  factory fromJson(Map<String, dynamic> json) => _$ArtistInfoFromJson(json);
}
