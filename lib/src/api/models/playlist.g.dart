// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'playlist.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Playlist _$PlaylistFromJson(Map<String, dynamic> json) => _Playlist(
  id: json['id'] as String,
  name: json['name'] as String,
  songCount: (json['songCount'] as num?)?.toInt(),
  duration: (json['duration'] as num?)?.toInt(),
  owner: json['owner'] as String?,
  isPublic: json['public'] as bool?,
  coverArt: json['coverArt'] as String?,
  comment: json['comment'] as String?,
  entries:
      (json['entries'] as List<dynamic>?)
          ?.map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <Song>[],
);

Map<String, dynamic> _$PlaylistToJson(_Playlist instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'songCount': instance.songCount,
  'duration': instance.duration,
  'owner': instance.owner,
  'public': instance.isPublic,
  'coverArt': instance.coverArt,
  'comment': instance.comment,
  'entries': instance.entries,
};
