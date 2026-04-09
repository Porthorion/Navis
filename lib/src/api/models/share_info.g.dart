// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'share_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ShareInfo _$ShareInfoFromJson(Map<String, dynamic> json) => _ShareInfo(
  id: json['id'] as String,
  url: json['url'] as String?,
  description: json['description'] as String?,
  expires: json['expires'] == null
      ? null
      : DateTime.parse(json['expires'] as String),
  created: json['created'] == null
      ? null
      : DateTime.parse(json['created'] as String),
);

Map<String, dynamic> _$ShareInfoToJson(_ShareInfo instance) =>
    <String, dynamic>{
      'id': instance.id,
      'url': instance.url,
      'description': instance.description,
      'expires': instance.expires?.toIso8601String(),
      'created': instance.created?.toIso8601String(),
    };
