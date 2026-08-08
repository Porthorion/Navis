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
  sampleRate: (_readSampleRateJson(json, 'sampleRate') as num?)?.toInt(),
  contentType: json['contentType'] as String?,
  suffix: json['suffix'] as String?,
  size: (json['size'] as num?)?.toInt(),
  coverArt: json['coverArt'] as String?,
  starred: json['starred'] == null
      ? null
      : DateTime.parse(json['starred'] as String),
  musicBrainzId: json['musicBrainzId'] as String?,
  userRating: (json['userRating'] as num?)?.toInt(),
  playCount: (json['playCount'] as num?)?.toInt(),
  created: json['created'] == null
      ? null
      : DateTime.parse(json['created'] as String),
  isExternal: json['isExternal'] as bool?,
  replayGain: json['replayGain'] == null
      ? null
      : ReplayGain.fromJson(json['replayGain'] as Map<String, dynamic>),
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
  'sampleRate': instance.sampleRate,
  'contentType': instance.contentType,
  'suffix': instance.suffix,
  'size': instance.size,
  'coverArt': instance.coverArt,
  'starred': instance.starred?.toIso8601String(),
  'musicBrainzId': instance.musicBrainzId,
  'userRating': instance.userRating,
  'playCount': instance.playCount,
  'created': instance.created?.toIso8601String(),
  'isExternal': instance.isExternal,
  'replayGain': instance.replayGain?.toJson(),
};

_ReplayGain _$ReplayGainFromJson(Map<String, dynamic> json) => _ReplayGain(
  trackGain: (json['trackGain'] as num?)?.toDouble(),
  albumGain: (json['albumGain'] as num?)?.toDouble(),
  trackPeak: (json['trackPeak'] as num?)?.toDouble(),
  albumPeak: (json['albumPeak'] as num?)?.toDouble(),
);

Map<String, dynamic> _$ReplayGainToJson(_ReplayGain instance) =>
    <String, dynamic>{
      'trackGain': instance.trackGain,
      'albumGain': instance.albumGain,
      'trackPeak': instance.trackPeak,
      'albumPeak': instance.albumPeak,
    };
