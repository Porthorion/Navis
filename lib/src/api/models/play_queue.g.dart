// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'play_queue.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_PlayQueue _$PlayQueueFromJson(Map<String, dynamic> json) => _PlayQueue(
  current: json['current'] as String?,
  position: (json['position'] as num?)?.toInt(),
  username: json['username'] as String?,
  changed: (json['changed'] as num?)?.toInt(),
  entries:
      (json['entries'] as List<dynamic>?)
          ?.map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <Song>[],
);

Map<String, dynamic> _$PlayQueueToJson(_PlayQueue instance) =>
    <String, dynamic>{
      'current': instance.current,
      'position': instance.position,
      'username': instance.username,
      'changed': instance.changed,
      'entries': instance.entries,
    };
