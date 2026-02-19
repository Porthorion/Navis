// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'artist_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ArtistInfo _$ArtistInfoFromJson(Map<String, dynamic> json) => _ArtistInfo(
  biography: json['biography'] as String?,
  musicBrainzId: json['musicBrainzId'] as String?,
  lastFmUrl: json['lastFmUrl'] as String?,
  smallImageUrl: json['smallImageUrl'] as String?,
  mediumImageUrl: json['mediumImageUrl'] as String?,
  largeImageUrl: json['largeImageUrl'] as String?,
  similarArtists:
      (json['similarArtists'] as List<dynamic>?)
          ?.map((e) => Artist.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <Artist>[],
);

Map<String, dynamic> _$ArtistInfoToJson(_ArtistInfo instance) =>
    <String, dynamic>{
      'biography': instance.biography,
      'musicBrainzId': instance.musicBrainzId,
      'lastFmUrl': instance.lastFmUrl,
      'smallImageUrl': instance.smallImageUrl,
      'mediumImageUrl': instance.mediumImageUrl,
      'largeImageUrl': instance.largeImageUrl,
      'similarArtists': instance.similarArtists,
    };
