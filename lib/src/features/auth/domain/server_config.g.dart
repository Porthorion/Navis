// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ServerConfigModel _$ServerConfigModelFromJson(Map<String, dynamic> json) =>
    _ServerConfigModel(
      id: (json['id'] as num?)?.toInt(),
      name: json['name'] as String?,
      url: json['url'] as String,
      username: json['username'] as String,
      password: json['password'] as String,
      apiVersion: json['apiVersion'] as String,
      useLegacyAuth: json['useLegacyAuth'] as bool? ?? false,
      capabilitiesJson: json['capabilitiesJson'] as String?,
      lastSynced: json['lastSynced'] == null
          ? null
          : DateTime.parse(json['lastSynced'] as String),
      lastFullSyncedAt: json['lastFullSyncedAt'] == null
          ? null
          : DateTime.parse(json['lastFullSyncedAt'] as String),
    );

Map<String, dynamic> _$ServerConfigModelToJson(_ServerConfigModel instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'url': instance.url,
      'username': instance.username,
      'password': instance.password,
      'apiVersion': instance.apiVersion,
      'useLegacyAuth': instance.useLegacyAuth,
      'capabilitiesJson': instance.capabilitiesJson,
      'lastSynced': instance.lastSynced?.toIso8601String(),
      'lastFullSyncedAt': instance.lastFullSyncedAt?.toIso8601String(),
    };
