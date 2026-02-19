import 'package:freezed_annotation/freezed_annotation.dart';

part 'album_info.freezed.dart';
part 'album_info.g.dart';

@freezed
abstract class AlbumInfo with _$AlbumInfo {
  const factory AlbumInfo({
    String? notes,
    String? musicBrainzId,
    String? lastFmUrl,
    String? smallImageUrl,
    String? mediumImageUrl,
    String? largeImageUrl,
  }) = _AlbumInfo;

  factory AlbumInfo.fromJson(Map<String, dynamic> json) =>
      _$AlbumInfoFromJson(json);
}
