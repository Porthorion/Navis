import 'dart:convert';

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

  const new _();

  factory fromJson(Map<String, dynamic> json) =>
      _$ServerCapabilitiesFromJson(json);

  /// Navidrome's OpenSubsonic `transcodeOffset`: `stream.view` accepts a
  /// `timeOffset` start second on a transcode.
  bool get supportsTranscodeOffset =>
      extensions.any((extension) => extension.name == 'transcodeOffset');

  /// Reads the capability JSON stored in `server_config.capabilities`, which
  /// may be absent, empty or invalid legacy text.
  static bool supportsTranscodeOffsetIn(String? capabilitiesJson) {
    if (capabilitiesJson == null || capabilitiesJson.trim().isEmpty) {
      return false;
    }
    try {
      final decoded = jsonDecode(capabilitiesJson);
      return decoded is Map<String, dynamic> &&
          ServerCapabilities.fromJson(decoded).supportsTranscodeOffset;
    } on FormatException {
      return false;
    }
  }
}
