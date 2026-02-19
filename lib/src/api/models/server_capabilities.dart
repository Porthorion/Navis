import 'package:freezed_annotation/freezed_annotation.dart';

part 'server_capabilities.freezed.dart';
part 'server_capabilities.g.dart';

@freezed
abstract class OpenSubsonicExtension with _$OpenSubsonicExtension {
  const factory OpenSubsonicExtension({
    required String name,
    @Default(<String>[]) List<String> versions,
  }) = _OpenSubsonicExtension;

  factory OpenSubsonicExtension.fromJson(Map<String, dynamic> json) =>
      _$OpenSubsonicExtensionFromJson(json);
}

@freezed
abstract class ServerCapabilities with _$ServerCapabilities {
  const factory ServerCapabilities({
    @Default(<OpenSubsonicExtension>[]) List<OpenSubsonicExtension> extensions,
  }) = _ServerCapabilities;

  factory ServerCapabilities.fromJson(Map<String, dynamic> json) =>
      _$ServerCapabilitiesFromJson(json);
}
