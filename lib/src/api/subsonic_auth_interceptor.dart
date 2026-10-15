import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

/// Auth strategy used for Subsonic requests.
enum SubsonicAuthType { token, legacyPassword }

/// Credentials and protocol fields injected into every request.
class SubsonicAuthConfig {
  const new({
    required this.username,
    required this.password,
    required this.apiVersion,
    this.client = 'Navis',
    this.authType = SubsonicAuthType.token,
  });

  final String username;
  final String password;
  final String apiVersion;
  final String client;
  final SubsonicAuthType authType;
}

/// Builds the Subsonic authentication and protocol query parameters.
Map<String, String> buildSubsonicAuthQuery(
  SubsonicAuthConfig config,
  Uuid uuid,
) {
  final query = <String, String>{
    'u': config.username,
    'v': config.apiVersion,
    'c': config.client,
    'f': 'json',
  };
  switch (config.authType) {
    case SubsonicAuthType.token:
      final salt = uuid.v4().replaceAll('-', '').substring(0, 12);
      query
        ..['s'] = salt
        ..['t'] = md5
            .convert(utf8.encode('${config.password}$salt'))
            .toString();
    case SubsonicAuthType.legacyPassword:
      query['p'] = 'enc:${hex.encode(utf8.encode(config.password))}';
  }
  return query;
}

/// Appends required Subsonic auth and protocol query parameters.
class SubsonicAuthInterceptor extends Interceptor {
  new({required this.config, Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final SubsonicAuthConfig config;
  final Uuid _uuid;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final query = <String, dynamic>{
      ...options.queryParameters,
      ...buildSubsonicAuthQuery(config, _uuid),
    };

    switch (config.authType) {
      case SubsonicAuthType.token:
        query.remove('p');
      case SubsonicAuthType.legacyPassword:
        query
          ..remove('t')
          ..remove('s');
    }

    handler.next(options.copyWith(queryParameters: query));
  }
}
