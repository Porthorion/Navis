// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'genre.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Genre _$GenreFromJson(Map<String, dynamic> json) => _Genre(
  name: json['name'] as String,
  songCount: (json['songCount'] as num?)?.toInt(),
  albumCount: (json['albumCount'] as num?)?.toInt(),
);

Map<String, dynamic> _$GenreToJson(_Genre instance) => <String, dynamic>{
  'name': instance.name,
  'songCount': instance.songCount,
  'albumCount': instance.albumCount,
};
