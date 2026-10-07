import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

/// Shared recording boundary for image transports and their early policy gates.
///
/// Cache hits are not requests. A gate records only refusals; the transport
/// records each dispatched hop, including redirects, once it finishes.
class ArtworkCallRecorder {
  new({required this.isServerUri, this.recorder});

  final bool Function(Uri) isServerUri;
  final IntegrationCallRecorder? recorder;

  bool checkAllowed(Uri uri, {required bool allowed}) {
    if (!allowed) {
      record(uri, outcome: IntegrationCallOutcome.blocked);
    }
    return allowed;
  }

  void record(
    Uri uri, {
    required IntegrationCallOutcome outcome,
    Duration duration = Duration.zero,
    int? statusCode,
  }) {
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        isServerUri(uri)) {
      return;
    }
    recorder?.recordCall(
      service: IntegrationService.serverLinkedArtwork,
      method: 'GET',
      uri: uri,
      duration: duration,
      outcome: outcome,
      statusCode: statusCode,
    );
  }
}
