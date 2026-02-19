import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/api/models/song.dart';

part 'playlist.freezed.dart';
part 'playlist.g.dart';

@freezed
abstract class Playlist with _$Playlist {
  const factory Playlist({
    required String id,
    required String name,
    int? songCount,
    int? duration,
    String? owner,
    @JsonKey(name: 'public') bool? isPublic,
    String? coverArt,
    String? comment,
    @Default(<Song>[]) List<Song> entries,
  }) = _Playlist;

  factory Playlist.fromJson(Map<String, dynamic> json) =>
      _$PlaylistFromJson(json);
}
