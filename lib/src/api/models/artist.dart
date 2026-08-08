import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/api/models/album.dart';

part 'artist.freezed.dart';
part 'artist.g.dart';

@freezed
abstract class Artist with _$Artist {
  const factory Artist({
    required String id,
    required String name,
    int? albumCount,
    String? coverArt,
    DateTime? starred,
    bool? isExternal,
    @Default(<Album>[]) List<Album> albums,
  }) = _Artist;

  factory Artist.fromJson(Map<String, dynamic> json) => _$ArtistFromJson(json);
}
