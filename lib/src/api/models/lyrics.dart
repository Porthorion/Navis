import 'package:freezed_annotation/freezed_annotation.dart';

part 'lyrics.freezed.dart';
part 'lyrics.g.dart';

@freezed
abstract class LyricLine with _$LyricLine {
  const factory({int? start, int? duration, String? value}) = _LyricLine;

  factory fromJson(Map<String, dynamic> json) => _$LyricLineFromJson(json);
}

@freezed
abstract class StructuredLyrics with _$StructuredLyrics {
  const factory({
    String? lang,
    bool? synced,
    @Default(<LyricLine>[]) List<LyricLine> line,
  }) = _StructuredLyrics;

  factory fromJson(Map<String, dynamic> json) =>
      _$StructuredLyricsFromJson(json);
}

@freezed
abstract class LyricsList with _$LyricsList {
  const factory({
    @Default(<StructuredLyrics>[]) List<StructuredLyrics> structuredLyrics,
    String? value,
  }) = _LyricsList;

  factory fromJson(Map<String, dynamic> json) => _$LyricsListFromJson(json);
}
