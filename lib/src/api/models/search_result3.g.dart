// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'search_result3.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_SearchResult3 _$SearchResult3FromJson(Map<String, dynamic> json) =>
    _SearchResult3(
      artists:
          (json['artists'] as List<dynamic>?)
              ?.map((e) => Artist.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <Artist>[],
      albums:
          (json['albums'] as List<dynamic>?)
              ?.map((e) => Album.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <Album>[],
      songs:
          (json['songs'] as List<dynamic>?)
              ?.map((e) => Song.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <Song>[],
    );

Map<String, dynamic> _$SearchResult3ToJson(_SearchResult3 instance) =>
    <String, dynamic>{
      'artists': instance.artists,
      'albums': instance.albums,
      'songs': instance.songs,
    };
