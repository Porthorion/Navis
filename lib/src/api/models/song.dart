import 'package:freezed_annotation/freezed_annotation.dart';

part 'song.freezed.dart';
part 'song.g.dart';

@freezed
abstract class Song with _$Song {
  const factory Song({
    required String id,
    required String title,
    String? album,
    String? albumId,
    String? artist,
    String? artistId,
    int? track,
    int? discNumber,
    int? year,
    int? duration,
    int? bitRate,
    String? contentType,
    String? suffix,
    int? size,
    String? coverArt,
    DateTime? starred,
    int? playCount,
  }) = _Song;

  factory Song.fromJson(Map<String, dynamic> json) => _$SongFromJson(json);
}
