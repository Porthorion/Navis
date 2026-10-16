import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/api/models/song.dart';

part 'playlist.freezed.dart';
part 'playlist.g.dart';

@freezed
abstract class Playlist with _$Playlist {
  const factory({
    required String id,
    required String name,
    int? songCount,
    int? duration,
    String? owner,
    @JsonKey(name: 'public') bool? isPublic,
    @JsonKey(name: 'readonly') bool? readOnly,
    String? coverArt,
    String? comment,
    DateTime? changed,
    @Default(<Song>[]) List<Song> entries,
  }) = _Playlist;

  factory fromJson(Map<String, dynamic> json) => _$PlaylistFromJson(json);
}
