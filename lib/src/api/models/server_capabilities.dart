import 'package:freezed_annotation/freezed_annotation.dart';

part 'server_capabilities.freezed.dart';
part 'server_capabilities.g.dart';

@freezed
abstract class OpenSubsonicExtension with _$OpenSubsonicExtension {
  const factory({
    required String name,
    @Default(<String>[]) List<String> versions,
  }) = _OpenSubsonicExtension;

  factory fromJson(Map<String, dynamic> json) =>
      _$OpenSubsonicExtensionFromJson(json);
}

@freezed
abstract class ServerCapabilities with _$ServerCapabilities {
  const factory({
    @Default(<OpenSubsonicExtension>[]) List<OpenSubsonicExtension> extensions,
  }) = _ServerCapabilities;

  factory fromJson(Map<String, dynamic> json) =>
      _$ServerCapabilitiesFromJson(json);
}
