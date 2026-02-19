import 'package:freezed_annotation/freezed_annotation.dart';

part 'lyrics.freezed.dart';
part 'lyrics.g.dart';

@freezed
abstract class LyricLine with _$LyricLine {
  const factory LyricLine({
    int? start,
    int? duration,
    String? value,
  }) = _LyricLine;

  factory LyricLine.fromJson(Map<String, dynamic> json) =>
      _$LyricLineFromJson(json);
}

@freezed
abstract class StructuredLyrics with _$StructuredLyrics {
  const factory StructuredLyrics({
    String? lang,
    bool? synced,
    @Default(<LyricLine>[]) List<LyricLine> line,
  }) = _StructuredLyrics;

  factory StructuredLyrics.fromJson(Map<String, dynamic> json) =>
      _$StructuredLyricsFromJson(json);
}

@freezed
abstract class LyricsList with _$LyricsList {
  const factory LyricsList({
    @Default(<StructuredLyrics>[]) List<StructuredLyrics> structuredLyrics,
    String? value,
  }) = _LyricsList;

  factory LyricsList.fromJson(Map<String, dynamic> json) =>
      _$LyricsListFromJson(json);
}
