import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Retries transient Subsonic request failures with exponential backoff.
class SubsonicRetryInterceptor extends Interceptor {
  SubsonicRetryInterceptor({
    required this.dio,
    this.maxRetries = 3,
    Duration Function(int attempt)? backoff,
  }) : _backoff = backoff ?? _defaultBackoff;

  static const _attemptKey = 'subsonic_retry_attempt';

  final Dio dio;
  final int maxRetries;
  final Duration Function(int attempt) _backoff;

  static Duration _defaultBackoff(int attempt) =>
      Duration(seconds: 1 << (attempt - 1));

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    var currentError = err;
    var attempt = (err.requestOptions.extra[_attemptKey] as int?) ?? 0;

    while (_shouldRetry(currentError) && attempt < maxRetries) {
      attempt += 1;

      AppLogger.debug(
        'Retrying ${currentError.requestOptions.path} '
        '(attempt $attempt/$maxRetries)',
      );

      final updatedExtra = Map<String, dynamic>.from(
        currentError.requestOptions.extra,
      )..[_attemptKey] = attempt;

      final retryOptions = currentError.requestOptions.copyWith(
        extra: updatedExtra,
      );

      await Future<void>.delayed(_backoff(attempt));

      try {
        final response = await dio.fetch<dynamic>(retryOptions);
        handler.resolve(response);
        return;
      } on DioException catch (retryError) {
        currentError = retryError;
      }
    }

    handler.next(currentError);
  }

  bool _shouldRetry(DioException err) {
    if (err.type == DioExceptionType.cancel) {
      return false;
    }

    final error = err.error;
    if (error is SocketException || error is TimeoutException) {
      return true;
    }

    final status = err.response?.statusCode;
    return status != null && status >= 500 && status < 600;
  }
}
