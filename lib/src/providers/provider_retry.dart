import 'dart:async';
import 'dart:io';

import 'package:navis/src/api/subsonic_error.dart';

/// HTTP statuses a server sends for overload or maintenance, which can pass
/// on their own.
const _transientHttpStatuses = <int>{429, 502, 503, 504, 530};

const _maxRetries = 3;
const _firstRetryDelay = Duration(milliseconds: 200);

/// How Navis retries a provider that failed, for every [ProviderContainer].
///
/// Riverpod 3 retries any failed provider up to ten times by default (about
/// 40 seconds with its backoff) and reports the attempts as loading, so a
/// page whose server rejects a request showed loading placeholders for that
/// long and asked the server again each time. Only failures that can pass on
/// their own (a dropped connection, a server that is busy or restarting) are
/// retried, three times within about 1.4 seconds; any other error is shown at
/// once. The Subsonic client already retries a transient request once.
Duration? navisProviderRetry(int retryCount, Object error) {
  if (retryCount >= _maxRetries || !isTransientProviderError(error)) {
    return null;
  }
  return _firstRetryDelay * (1 << retryCount);
}

/// Whether [error] may succeed when the same request is made again shortly.
bool isTransientProviderError(Object error) => switch (error) {
  SubsonicConnectionException() ||
  SocketException() ||
  TimeoutException() => true,
  SubsonicGenericException(:final code?) => _transientHttpStatuses.contains(
    code,
  ),
  _ => false,
};
