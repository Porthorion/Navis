// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'album_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AlbumInfo _$AlbumInfoFromJson(Map<String, dynamic> json) => _AlbumInfo(
  notes: json['notes'] as String?,
  musicBrainzId: json['musicBrainzId'] as String?,
  lastFmUrl: json['lastFmUrl'] as String?,
  smallImageUrl: json['smallImageUrl'] as String?,
  mediumImageUrl: json['mediumImageUrl'] as String?,
  largeImageUrl: json['largeImageUrl'] as String?,
);

Map<String, dynamic> _$AlbumInfoToJson(_AlbumInfo instance) =>
    <String, dynamic>{
      'notes': instance.notes,
      'musicBrainzId': instance.musicBrainzId,
      'lastFmUrl': instance.lastFmUrl,
      'smallImageUrl': instance.smallImageUrl,
      'mediumImageUrl': instance.mediumImageUrl,
      'largeImageUrl': instance.largeImageUrl,
    };
