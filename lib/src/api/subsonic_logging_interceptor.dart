import 'package:dio/dio.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Logs request method, URL, status and duration with auth parameter redaction.
class SubsonicLoggingInterceptor extends Interceptor {
  static const _startKey = 'subsonic_request_start_ms';
  static const _retryAttemptKey = 'subsonic_retry_attempt';
  static const _sensitiveParams = {'u', 't', 's', 'p'};

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    options.extra[_startKey] = DateTime.now().millisecondsSinceEpoch;
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final elapsedMs = _elapsed(response.requestOptions);
    AppLogger.info(
      '${response.requestOptions.method} '
      '${redactUri(response.requestOptions.uri)} '
      '-> ${response.statusCode} (${elapsedMs}ms)',
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.type == DioExceptionType.cancel) {
      final elapsedMs = _elapsed(err.requestOptions);
      AppLogger.debug(
        '${err.requestOptions.method} '
        '${redactUri(err.requestOptions.uri)} '
        '-> canceled (${elapsedMs}ms)',
      );
      handler.next(err);
      return;
    }

    final elapsedMs = _elapsed(err.requestOptions);
    final retryAttempt =
        (err.requestOptions.extra[_retryAttemptKey] as int?) ?? 0;
    if (retryAttempt > 0) {
      AppLogger.debug(
        '${err.requestOptions.method} '
        '${redactUri(err.requestOptions.uri)} '
        '-> retry-attempt-failed($retryAttempt) (${elapsedMs}ms)',
      );
      handler.next(err);
      return;
    }

    AppLogger.warning(
      '${err.requestOptions.method} '
      '${redactUri(err.requestOptions.uri)} '
      '-> ${err.response?.statusCode ?? 'error'} (${elapsedMs}ms)',
    );
    handler.next(err);
  }

  int _elapsed(RequestOptions options) {
    final start = options.extra[_startKey] as int?;
    if (start == null) {
      return 0;
    }
    return DateTime.now().millisecondsSinceEpoch - start;
  }

  static Uri redactUri(Uri uri) {
    final redacted = <String, String>{};
    for (final entry in uri.queryParameters.entries) {
      redacted[entry.key] = _sensitiveParams.contains(entry.key)
          ? 'REDACTED'
          : entry.value;
    }
    return uri.replace(queryParameters: redacted);
  }
}
