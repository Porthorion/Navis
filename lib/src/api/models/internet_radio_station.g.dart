// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'internet_radio_station.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_InternetRadioStation _$InternetRadioStationFromJson(
  Map<String, dynamic> json,
) => _InternetRadioStation(
  id: json['id'] as String,
  name: json['name'] as String,
  streamUrl: json['streamUrl'] as String,
  homePageUrl: json['homePageUrl'] as String?,
);

Map<String, dynamic> _$InternetRadioStationToJson(
  _InternetRadioStation instance,
) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'streamUrl': instance.streamUrl,
  'homePageUrl': instance.homePageUrl,
};
