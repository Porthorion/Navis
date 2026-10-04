import 'package:dio/dio.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

/// Builds the [Dio] for an external client, with [service]'s guard and call
/// recording installed. Every client of a service other than the user's own
/// server takes its [Dio] from here, so none can bypass the policy.
///
/// [readPolicy] runs on every request, so a change to the user's choices
/// applies to clients that already exist.
Dio createExternalDio(
  IntegrationService service, {
  required IntegrationPolicy Function() readPolicy,
  IntegrationCallRecorder? recorder,
  BaseOptions? options,
}) {
  final dio = Dio(options);
  dio.interceptors.add(
    IntegrationGuardInterceptor(
      service: service,
      readPolicy: readPolicy,
      recorder: recorder,
    ),
  );
  return dio;
}

/// Creates the guarded [Dio] for a service. Provided by
/// `externalDioFactoryProvider`.
typedef ExternalDioFactory = Dio Function(
  IntegrationService service, {
  BaseOptions? options,
});
