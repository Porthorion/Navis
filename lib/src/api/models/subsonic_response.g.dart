// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'subsonic_response.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_SubsonicErrorResponse _$SubsonicErrorResponseFromJson(
  Map<String, dynamic> json,
) => _SubsonicErrorResponse(
  code: (json['code'] as num?)?.toInt(),
  message: json['message'] as String?,
);

Map<String, dynamic> _$SubsonicErrorResponseToJson(
  _SubsonicErrorResponse instance,
) => <String, dynamic>{'code': instance.code, 'message': instance.message};

_SubsonicResponse<T> _$SubsonicResponseFromJson<T>(
  Map<String, dynamic> json,
  T Function(Object? json) fromJsonT,
) => _SubsonicResponse<T>(
  status: json['status'] as String,
  version: json['version'] as String?,
  type: json['type'] as String?,
  serverVersion: json['serverVersion'] as String?,
  openSubsonic: json['openSubsonic'] as bool?,
  error: json['error'] == null
      ? null
      : SubsonicErrorResponse.fromJson(json['error'] as Map<String, dynamic>),
  data: _$nullableGenericFromJson(json['data'], fromJsonT),
);

Map<String, dynamic> _$SubsonicResponseToJson<T>(
  _SubsonicResponse<T> instance,
  Object? Function(T value) toJsonT,
) => <String, dynamic>{
  'status': instance.status,
  'version': instance.version,
  'type': instance.type,
  'serverVersion': instance.serverVersion,
  'openSubsonic': instance.openSubsonic,
  'error': instance.error,
  'data': _$nullableGenericToJson(instance.data, toJsonT),
};

T? _$nullableGenericFromJson<T>(
  Object? input,
  T Function(Object? json) fromJson,
) => input == null ? null : fromJson(input);

Object? _$nullableGenericToJson<T>(
  T? input,
  Object? Function(T value) toJson,
) => input == null ? null : toJson(input);
