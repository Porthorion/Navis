import 'dart:io';

import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';

String _requiredEnv(String name) {
  final value = Platform.environment[name]?.trim();
  if (value == null || value.isEmpty) {
    stderr.writeln('Missing required environment variable: $name');
    exit(2);
  }
  return value;
}

String _optionalEnv(String name, String fallback) {
  final value = Platform.environment[name]?.trim();
  if (value == null || value.isEmpty) {
    return fallback;
  }
  return value;
}

bool _parseBoolEnv(String name, {required bool fallback}) {
  final raw = Platform.environment[name]?.trim();
  if (raw == null || raw.isEmpty) {
    return fallback;
  }

  final value = raw.toLowerCase();
  const truthy = <String>{'1', 'true', 'yes', 'on'};
  const falsy = <String>{'0', 'false', 'no', 'off'};

  if (truthy.contains(value)) {
    return true;
  }
  if (falsy.contains(value)) {
    return false;
  }

  stderr.writeln(
    'Invalid boolean for $name: "$raw". Accepted: true/false, 1/0, yes/no, on/off.',
  );
  exit(2);
}

String _displayHost(String baseUrl) {
  try {
    final uri = Uri.parse(baseUrl);
    if (uri.scheme.isEmpty || uri.host.isEmpty) {
      return '<invalid-url>';
    }

    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  } on FormatException {
    return '<invalid-url>';
  }
}

String _sanitizeMessage({
  required String message,
  required String username,
  required String password,
}) {
  var sanitized = message;
  if (username.isNotEmpty) {
    sanitized = sanitized.replaceAll(username, '<redacted-username>');
  }
  if (password.isNotEmpty) {
    sanitized = sanitized.replaceAll(password, '<redacted-password>');
  }

  return sanitized.replaceAllMapped(
    RegExp(r'([?&](?:u|t|s|p)=)[^&\s]+'),
    (match) => '${match.group(1)}<redacted>',
  );
}

void main() async {
  final baseUrl = _requiredEnv('NAVIS_SMOKE_BASE_URL');
  final username = _requiredEnv('NAVIS_SMOKE_USERNAME');
  final password = _requiredEnv('NAVIS_SMOKE_PASSWORD');
  final apiVersion = _optionalEnv('NAVIS_SMOKE_API_VERSION', '1.16.1');
  final useLegacyAuth = _parseBoolEnv(
    'NAVIS_SMOKE_USE_LEGACY_AUTH',
    fallback: false,
  );

  final authType = useLegacyAuth
      ? SubsonicAuthType.legacyPassword
      : SubsonicAuthType.token;

  final client = SubsonicApiClient(
    baseUrl: baseUrl,
    authConfig: SubsonicAuthConfig(
      username: username,
      password: password,
      apiVersion: apiVersion,
      authType: authType,
    ),
    enableLogging: false,
  );

  final displayHost = _displayHost(baseUrl);

  try {
    await client.ping();
    final capabilities = await client.getOpenSubsonicExtensions();

    stdout.writeln(
      'Phase 1 smoke ping OK: host=$displayHost auth=${authType.name} apiVersion=$apiVersion',
    );
    stdout.writeln(
      'Phase 1 smoke capabilities: openSubsonicExtensions=${capabilities.extensions.length}',
    );
  } on SubsonicException catch (error) {
    final message = _sanitizeMessage(
      message: error.message,
      username: username,
      password: password,
    );
    stderr.writeln(
      'Phase 1 smoke ping failed: host=$displayHost error=${error.runtimeType} message="$message"',
    );
    exit(1);
  } on Object catch (error) {
    final message = _sanitizeMessage(
      message: error.toString(),
      username: username,
      password: password,
    );
    stderr.writeln(
      'Phase 1 smoke ping failed: host=$displayHost error=$message',
    );
    exit(1);
  }
}
