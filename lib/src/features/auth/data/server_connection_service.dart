import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';

class ServerConnectionProbeResult {
  const new({
    required this.apiVersion,
    required this.useLegacyAuth,
    required this.capabilities,
  });

  final String apiVersion;
  final bool useLegacyAuth;
  final ServerCapabilities capabilities;

  ServerConnectionProbeResult copyWith({bool? useLegacyAuth}) {
    return ServerConnectionProbeResult(
      apiVersion: apiVersion,
      useLegacyAuth: useLegacyAuth ?? this.useLegacyAuth,
      capabilities: capabilities,
    );
  }
}

abstract class ServerConnectionService {
  const new();

  Future<ServerConnectionProbeResult> probe({
    required String url,
    required String username,
    required String password,
  });
}

class SubsonicServerConnectionService extends ServerConnectionService {
  const new();

  static const _defaultApiVersion = '1.16.1';

  @override
  Future<ServerConnectionProbeResult> probe({
    required String url,
    required String username,
    required String password,
  }) async {
    try {
      return await _probeWithAuthType(
        url: url,
        username: username,
        password: password,
        authType: SubsonicAuthType.token,
      );
    } on SubsonicAuthException {
      final fallback = await _probeWithAuthType(
        url: url,
        username: username,
        password: password,
        authType: SubsonicAuthType.legacyPassword,
      );
      return fallback.copyWith(useLegacyAuth: true);
    }
  }

  Future<ServerConnectionProbeResult> _probeWithAuthType({
    required String url,
    required String username,
    required String password,
    required SubsonicAuthType authType,
  }) async {
    final client = SubsonicApiClient(
      baseUrl: url,
      authConfig: SubsonicAuthConfig(
        username: username,
        password: password,
        apiVersion: _defaultApiVersion,
        authType: authType,
      ),
    );

    final apiVersion = await client.ping();
    final useLegacyAuth =
        authType == SubsonicAuthType.legacyPassword ||
        _requiresLegacyAuth(apiVersion);
    final capabilitiesClient = useLegacyAuth
        ? SubsonicApiClient(
            baseUrl: url,
            authConfig: SubsonicAuthConfig(
              username: username,
              password: password,
              apiVersion: apiVersion,
              authType: SubsonicAuthType.legacyPassword,
            ),
          )
        : SubsonicApiClient(
            baseUrl: url,
            authConfig: SubsonicAuthConfig(
              username: username,
              password: password,
              apiVersion: apiVersion,
              authType: authType,
            ),
          );

    final capabilities = await _getCapabilitiesOrDefault(capabilitiesClient);
    return ServerConnectionProbeResult(
      apiVersion: apiVersion,
      useLegacyAuth: useLegacyAuth,
      capabilities: capabilities,
    );
  }

  Future<ServerCapabilities> _getCapabilitiesOrDefault(
    SubsonicApiClient client,
  ) async {
    try {
      return await client.getOpenSubsonicExtensions();
    } on SubsonicNotFoundException {
      return const ServerCapabilities();
    } on SubsonicGenericException catch (error) {
      if (error.code == 404 || error.code == 501) {
        return const ServerCapabilities();
      }
      rethrow;
    }
  }

  bool _requiresLegacyAuth(String version) {
    final parts = version
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
    if (parts.length < 2) {
      return false;
    }
    final major = parts[0];
    final minor = parts[1];
    if (major < 1) {
      return true;
    }
    return major == 1 && minor < 13;
  }
}
