// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'song.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Song _$SongFromJson(Map<String, dynamic> json) => _Song(
  id: json['id'] as String,
  title: json['title'] as String,
  album: json['album'] as String?,
  albumId: json['albumId'] as String?,
  artist: json['artist'] as String?,
  artistId: json['artistId'] as String?,
  track: (json['track'] as num?)?.toInt(),
  discNumber: (json['discNumber'] as num?)?.toInt(),
  year: (json['year'] as num?)?.toInt(),
  duration: (json['duration'] as num?)?.toInt(),
  bitRate: (json['bitRate'] as num?)?.toInt(),
  contentType: json['contentType'] as String?,
  suffix: json['suffix'] as String?,
  size: (json['size'] as num?)?.toInt(),
  coverArt: json['coverArt'] as String?,
  starred: json['starred'] == null
      ? null
      : DateTime.parse(json['starred'] as String),
  playCount: (json['playCount'] as num?)?.toInt(),
);

Map<String, dynamic> _$SongToJson(_Song instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'album': instance.album,
  'albumId': instance.albumId,
  'artist': instance.artist,
  'artistId': instance.artistId,
  'track': instance.track,
  'discNumber': instance.discNumber,
  'year': instance.year,
  'duration': instance.duration,
  'bitRate': instance.bitRate,
  'contentType': instance.contentType,
  'suffix': instance.suffix,
  'size': instance.size,
  'coverArt': instance.coverArt,
  'starred': instance.starred?.toIso8601String(),
  'playCount': instance.playCount,
};
