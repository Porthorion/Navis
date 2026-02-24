// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'album.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Album _$AlbumFromJson(Map<String, dynamic> json) => _Album(
  id: json['id'] as String,
  name: json['name'] as String,
  artist: json['artist'] as String?,
  artistId: json['artistId'] as String?,
  songCount: (json['songCount'] as num?)?.toInt(),
  duration: (json['duration'] as num?)?.toInt(),
  year: (json['year'] as num?)?.toInt(),
  genre: json['genre'] as String?,
  coverArt: json['coverArt'] as String?,
  starred: json['starred'] == null
      ? null
      : DateTime.parse(json['starred'] as String),
  playCount: (json['playCount'] as num?)?.toInt(),
  created: json['created'] == null
      ? null
      : DateTime.parse(json['created'] as String),
  songs:
      (json['songs'] as List<dynamic>?)
          ?.map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <Song>[],
);

Map<String, dynamic> _$AlbumToJson(_Album instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'artist': instance.artist,
  'artistId': instance.artistId,
  'songCount': instance.songCount,
  'duration': instance.duration,
  'year': instance.year,
  'genre': instance.genre,
  'coverArt': instance.coverArt,
  'starred': instance.starred?.toIso8601String(),
  'playCount': instance.playCount,
  'created': instance.created?.toIso8601String(),
  'songs': instance.songs,
};
