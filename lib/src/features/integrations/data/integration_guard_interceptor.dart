import 'package:dio/dio.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

/// `RequestOptions.extra` key set by calls the user triggered directly:
/// validating a key or token, "Check now", AutoEQ refresh and download.
///
/// Such a call is allowed while its service switch is off, because the user
/// just asked for it. It is still blocked when the master switch is off.
const navisUserInitiatedExtraKey = 'navis.userInitiated';

/// [Options] for a user-initiated call, merged onto [base] when given.
Options userInitiatedOptions([Options? base]) {
  final options = base ?? Options();
  return options.copyWith(
    extra: <String, dynamic>{
      ...?options.extra,
      navisUserInitiatedExtraKey: true,
    },
  );
}

/// Thrown, wrapped in a [DioException], when the guard stops a request.
class IntegrationBlockedException implements Exception {
  const new(this.service);

  final IntegrationService service;

  @override
  String toString() =>
      'IntegrationBlockedException: ${service.displayName} is turned off';
}

/// Defense in depth for the call-site gates: rejects a request for a disabled
/// service, or any request while the master switch is off, before it leaves
/// the device, and records every call.
///
/// A Deezer response whose body carries an error (HTTP 200 with
/// `{"error": {...}}`, such as code 4 for the quota) is recorded as
/// [IntegrationCallOutcome.serviceError]; code 800 ("no data") is an answer
/// and stays [IntegrationCallOutcome.ok]. Only the outcome is kept, never
/// the body.
///
/// It checks service-level enablement only; whether a particular feature of
/// the service is on is decided where the feature is used.
class IntegrationGuardInterceptor extends Interceptor {
  new({required this.service, required this.readPolicy, this.recorder});

  final IntegrationService service;
  final IntegrationPolicy Function() readPolicy;
  final IntegrationCallRecorder? recorder;

  static const _startedExtraKey = 'navis.callStartedAt';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final policy = readPolicy();
    final userInitiated = options.extra[navisUserInitiatedExtraKey] == true;
    final allowed = userInitiated
        ? policy.masterEnabled
        : policy.isServiceEnabled(service);
    if (!allowed) {
      recorder?.recordCall(
        service: service,
        method: options.method,
        uri: options.uri,
        duration: Duration.zero,
        outcome: IntegrationCallOutcome.blocked,
      );
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: IntegrationBlockedException(service),
          message: '${service.displayName} is turned off',
        ),
      );
      return;
    }
    options.extra[_startedExtraKey] = DateTime.now().microsecondsSinceEpoch;
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _record(
      response.requestOptions,
      _reportsError(response)
          ? IntegrationCallOutcome.serviceError
          : IntegrationCallOutcome.ok,
      statusCode: response.statusCode,
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    // A blocked request was already recorded where it was rejected.
    if (err.error is! IntegrationBlockedException) {
      _record(
        err.requestOptions,
        IntegrationCallOutcome.error,
        statusCode: err.response?.statusCode,
      );
    }
    handler.next(err);
  }

  /// Whether the service reported an error in a successful response's body.
  bool _reportsError(Response<dynamic> response) {
    if (service != IntegrationService.deezer) return false;
    final error = DeezerApiClient.bodyError(response.data);
    return error != null && error.code != DeezerApiClient.noDataErrorCode;
  }

  void _record(
    RequestOptions options,
    IntegrationCallOutcome outcome, {
    int? statusCode,
  }) {
    final started = options.extra[_startedExtraKey];
    final elapsed = started is int
        ? Duration(
            microseconds: DateTime.now().microsecondsSinceEpoch - started,
          )
        : Duration.zero;
    recorder?.recordCall(
      service: service,
      method: options.method,
      uri: options.uri,
      duration: elapsed,
      outcome: outcome,
      statusCode: statusCode,
    );
  }
}
