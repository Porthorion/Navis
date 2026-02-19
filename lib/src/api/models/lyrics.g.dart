// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'lyrics.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_LyricLine _$LyricLineFromJson(Map<String, dynamic> json) => _LyricLine(
  start: (json['start'] as num?)?.toInt(),
  duration: (json['duration'] as num?)?.toInt(),
  value: json['value'] as String?,
);

Map<String, dynamic> _$LyricLineToJson(_LyricLine instance) =>
    <String, dynamic>{
      'start': instance.start,
      'duration': instance.duration,
      'value': instance.value,
    };

_StructuredLyrics _$StructuredLyricsFromJson(Map<String, dynamic> json) =>
    _StructuredLyrics(
      lang: json['lang'] as String?,
      synced: json['synced'] as bool?,
      line:
          (json['line'] as List<dynamic>?)
              ?.map((e) => LyricLine.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <LyricLine>[],
    );

Map<String, dynamic> _$StructuredLyricsToJson(_StructuredLyrics instance) =>
    <String, dynamic>{
      'lang': instance.lang,
      'synced': instance.synced,
      'line': instance.line,
    };

_LyricsList _$LyricsListFromJson(Map<String, dynamic> json) => _LyricsList(
  structuredLyrics:
      (json['structuredLyrics'] as List<dynamic>?)
          ?.map((e) => StructuredLyrics.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <StructuredLyrics>[],
  value: json['value'] as String?,
);

Map<String, dynamic> _$LyricsListToJson(_LyricsList instance) =>
    <String, dynamic>{
      'structuredLyrics': instance.structuredLyrics,
      'value': instance.value,
    };
