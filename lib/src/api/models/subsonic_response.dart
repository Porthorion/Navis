import 'package:freezed_annotation/freezed_annotation.dart';

part 'subsonic_response.freezed.dart';
part 'subsonic_response.g.dart';

@freezed
abstract class SubsonicErrorResponse with _$SubsonicErrorResponse {
  const factory({int? code, String? message}) = _SubsonicErrorResponse;

  factory fromJson(Map<String, dynamic> json) =>
      _$SubsonicErrorResponseFromJson(json);
}

@Freezed(genericArgumentFactories: true)
abstract class SubsonicResponse<T> with _$SubsonicResponse<T> {
  const factory({
    required String status,
    String? version,
    String? type,
    String? serverVersion,
    bool? openSubsonic,
    SubsonicErrorResponse? error,
    T? data,
  }) = _SubsonicResponse<T>;

  factory fromJson(Map<String, dynamic> json, T Function(Object?) fromJsonT) =>
      _$SubsonicResponseFromJson(json, fromJsonT);
}
