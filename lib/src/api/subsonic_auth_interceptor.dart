import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

/// Auth strategy used for Subsonic requests.
enum SubsonicAuthType {
  token,
  legacyPassword,
}

/// Credentials and protocol fields injected into every request.
class SubsonicAuthConfig {
  const SubsonicAuthConfig({
    required this.username,
    required this.password,
    required this.apiVersion,
    this.client = 'navis',
    this.authType = SubsonicAuthType.token,
  });

  final String username;
  final String password;
  final String apiVersion;
  final String client;
  final SubsonicAuthType authType;
}

/// Appends required Subsonic auth and protocol query parameters.
class SubsonicAuthInterceptor extends Interceptor {
  SubsonicAuthInterceptor({required this.config, Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final SubsonicAuthConfig config;
  final Uuid _uuid;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    final query = <String, dynamic>{
      ...options.queryParameters,
      'u': config.username,
      'v': config.apiVersion,
      'c': config.client,
      'f': 'json',
    };

    switch (config.authType) {
      case SubsonicAuthType.token:
        final salt = _uuid.v4().replaceAll('-', '').substring(0, 12);
        query
          ..['s'] = salt
          ..['t'] = md5
              .convert(utf8.encode('${config.password}$salt'))
              .toString()
          ..remove('p');
      case SubsonicAuthType.legacyPassword:
        query
          ..['p'] = 'enc:${_toHex(config.password)}'
          ..remove('t')
          ..remove('s');
    }

    handler.next(options.copyWith(queryParameters: query));
  }

  String _toHex(String value) {
    final buffer = StringBuffer();
    for (final byte in utf8.encode(value)) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
