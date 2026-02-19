// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_capabilities.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_OpenSubsonicExtension _$OpenSubsonicExtensionFromJson(
  Map<String, dynamic> json,
) => _OpenSubsonicExtension(
  name: json['name'] as String,
  versions:
      (json['versions'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const <String>[],
);

Map<String, dynamic> _$OpenSubsonicExtensionToJson(
  _OpenSubsonicExtension instance,
) => <String, dynamic>{'name': instance.name, 'versions': instance.versions};

_ServerCapabilities _$ServerCapabilitiesFromJson(Map<String, dynamic> json) =>
    _ServerCapabilities(
      extensions:
          (json['extensions'] as List<dynamic>?)
              ?.map(
                (e) =>
                    OpenSubsonicExtension.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          const <OpenSubsonicExtension>[],
    );

Map<String, dynamic> _$ServerCapabilitiesToJson(_ServerCapabilities instance) =>
    <String, dynamic>{'extensions': instance.extensions};
