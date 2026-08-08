// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'artist.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Artist _$ArtistFromJson(Map<String, dynamic> json) => _Artist(
  id: json['id'] as String,
  name: json['name'] as String,
  albumCount: (json['albumCount'] as num?)?.toInt(),
  coverArt: json['coverArt'] as String?,
  starred: json['starred'] == null
      ? null
      : DateTime.parse(json['starred'] as String),
  isExternal: json['isExternal'] as bool?,
  albums:
      (json['albums'] as List<dynamic>?)
          ?.map((e) => Album.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <Album>[],
);

Map<String, dynamic> _$ArtistToJson(_Artist instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'albumCount': instance.albumCount,
  'coverArt': instance.coverArt,
  'starred': instance.starred?.toIso8601String(),
  'isExternal': instance.isExternal,
  'albums': instance.albums,
};
