// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'indexes.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Indexes _$IndexesFromJson(Map<String, dynamic> json) => _Indexes(
  lastModified: _lastModifiedFromJson(json['lastModified']),
  indexes:
      (json['index'] as List<dynamic>?)
          ?.map((e) => IndexesIndex.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <IndexesIndex>[],
  shortcut:
      (json['shortcut'] as List<dynamic>?)
          ?.map((e) => Artist.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <Artist>[],
  child:
      (json['child'] as List<dynamic>?)
          ?.map((e) => Artist.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <Artist>[],
);

Map<String, dynamic> _$IndexesToJson(_Indexes instance) => <String, dynamic>{
  'lastModified': _lastModifiedToJson(instance.lastModified),
  'index': instance.indexes,
  'shortcut': instance.shortcut,
  'child': instance.child,
};

_IndexesIndex _$IndexesIndexFromJson(Map<String, dynamic> json) =>
    _IndexesIndex(
      name: json['name'] as String?,
      artists:
          (json['artist'] as List<dynamic>?)
              ?.map((e) => Artist.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <Artist>[],
    );

Map<String, dynamic> _$IndexesIndexToJson(_IndexesIndex instance) =>
    <String, dynamic>{'name': instance.name, 'artist': instance.artists};
