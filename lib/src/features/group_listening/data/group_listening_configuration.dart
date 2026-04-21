import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

GroupListeningAvailability resolveGroupListeningAvailability({
  required bool enabled,
  required String? voyageServerUrl,
  required ServerConfigModel? activeServer,
}) {
  if (!enabled) {
    return GroupListeningAvailability.disabled;
  }
  if (activeServer == null) {
    return GroupListeningAvailability.unconfigured;
  }
  final normalizedVoyageBaseUri = normalizeVoyageBaseUri(voyageServerUrl);
  if (normalizedVoyageBaseUri == null) {
    return GroupListeningAvailability.unconfigured;
  }
  if (!isVoyageTransportAllowed(normalizedVoyageBaseUri)) {
    return GroupListeningAvailability.unconfigured;
  }
  try {
    canonicalizeSourceServerOrigin(activeServer.url);
  } on Object {
    return GroupListeningAvailability.unconfigured;
  }
  return GroupListeningAvailability.ready;
}

GroupListeningClientConfiguration? buildGroupListeningClientConfiguration({
  required bool enabled,
  required String? voyageServerUrl,
  required String? displayName,
  required String? deviceLabel,
  required bool autoFollowHost,
  required ServerConfigModel? activeServer,
}) {
  if (resolveGroupListeningAvailability(
        enabled: enabled,
        voyageServerUrl: voyageServerUrl,
        activeServer: activeServer,
      ) !=
      GroupListeningAvailability.ready) {
    return null;
  }

  final voyageBaseUrl = normalizeVoyageBaseUri(voyageServerUrl)!;
  final server = activeServer!;
  final sourceServerOrigin = canonicalizeSourceServerOrigin(server.url);

  return GroupListeningClientConfiguration(
    voyageBaseUrl: voyageBaseUrl,
    sourceServerOrigin: sourceServerOrigin,
    sourceServerFingerprint: computeSourceServerFingerprint(server.url),
    displayName: _normalizedDisplayName(displayName, fallback: server.username),
    deviceLabel: _normalizeOptionalText(deviceLabel),
    autoFollowHost: autoFollowHost,
    allowInsecureTransport: voyageBaseUrl.scheme == 'http',
  );
}

Uri? normalizeVoyageBaseUri(String? rawUrl) {
  final trimmed = rawUrl?.trim() ?? '';
  if (trimmed.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
    return null;
  }
  return _canonicalizeBaseUri(uri);
}

String canonicalizeSourceServerOrigin(String rawUrl) {
  final uri = Uri.parse(rawUrl.trim());
  if (uri.scheme.isEmpty || uri.host.isEmpty) {
    throw const FormatException('Missing scheme or host.');
  }
  return _canonicalizeBaseUri(uri).toString();
}

String computeSourceServerFingerprint(String rawUrl) {
  final canonicalOrigin = canonicalizeSourceServerOrigin(rawUrl);
  final digest = sha256.convert(
    utf8.encode('navis-subsonic-origin-v1|$canonicalOrigin'),
  );
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

bool isVoyageTransportAllowed(Uri uri) {
  final normalizedScheme = uri.scheme.toLowerCase();
  if (normalizedScheme == 'https') {
    return true;
  }
  if (normalizedScheme != 'http') {
    return false;
  }
  return !kReleaseMode && _isLoopbackHost(uri.host);
}

Uri _canonicalizeBaseUri(Uri uri) {
  final normalizedScheme = uri.scheme.toLowerCase();
  final normalizedPath = _normalizePath(uri.path);
  final normalizedPort = _normalizedPort(
    normalizedScheme,
    uri.hasPort ? uri.port : null,
  );
  return Uri(
    scheme: normalizedScheme,
    host: uri.host.toLowerCase(),
    port: normalizedPort,
    path: normalizedPath,
  );
}

String _normalizePath(String path) {
  if (path.isEmpty || path == '/') {
    return '';
  }
  var normalized = path;
  while (normalized.endsWith('/') && normalized.length > 1) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

int? _normalizedPort(String scheme, int? port) {
  if (port == null) {
    return null;
  }
  if ((scheme == 'https' && port == 443) || (scheme == 'http' && port == 80)) {
    return null;
  }
  return port;
}

String _normalizedDisplayName(String? displayName, {required String fallback}) {
  final normalized = _normalizeOptionalText(displayName);
  if (normalized != null) {
    return normalized;
  }
  return fallback.trim();
}

String? _normalizeOptionalText(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1';
}
