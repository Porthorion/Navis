import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:navis/src/utils/app_logger.dart';

DateTime? subsonicRetryAt(String? value) {
  if (value == null) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null && seconds >= 0)
    return DateTime.now().toUtc().add(Duration(seconds: seconds));
  try {
    return HttpDate.parse(value.trim());
  } on FormatException {
    return null;
  }
}

/// Retries transient Subsonic request failures with exponential backoff.
class SubsonicRetryInterceptor extends Interceptor {
  SubsonicRetryInterceptor({
    required this.dio,
    this.maxRetries = 1,
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

      final delay = _retryDelay(currentError, attempt);
      // Long Retry-After guidance belongs to durable scheduling, not a
      // sleeping foreground request. Never retry sooner than the server asks.
      if (delay > const Duration(seconds: 10)) break;
      await Future<void>.delayed(delay);

      final beforeRetry = retryOptions.extra['navisBeforeSyncRetry'];
      if (beforeRetry is void Function(int)) {
        try {
          final data = currentError.response?.data;
          beforeRetry(data == null ? 0 : utf8.encode(jsonEncode(data)).length);
        } on Object catch (error) {
          handler.next(
            DioException(requestOptions: retryOptions, error: error),
          );
          return;
        }
      }

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

  Duration _retryDelay(DioException error, int attempt) {
    final retryAfter = error.response?.headers.value('retry-after')?.trim();
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter);
      if (seconds != null && seconds >= 0) {
        return Duration(seconds: seconds);
      }
      try {
        final date = HttpDate.parse(retryAfter);
        final remaining = date.difference(DateTime.now().toUtc());
        if (!remaining.isNegative) {
          return remaining;
        }
      } on FormatException {
        // Ignore malformed server guidance and use the bounded backoff.
      }
    }
    return _backoff(attempt);
  }

  bool _shouldRetry(DioException err) {
    if (err.requestOptions.extra['navisDisableRetry'] == true) {
      return false;
    }
    if (err.type == DioExceptionType.cancel) {
      return false;
    }

    final error = err.error;
    if (error is SocketException || error is TimeoutException) {
      return true;
    }

    final status = err.response?.statusCode;
    // Only retry rate limits and genuine server-side transient errors.
    // 501 "Not Implemented" is permanent — retrying is pointless.
    return status != null &&
        (status == 429 ||
            status == 502 ||
            status == 503 ||
            status == 504 ||
            status == 530);
  }
}
