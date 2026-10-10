/// Base class for Subsonic domain and transport exceptions.
sealed class SubsonicException implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Base class for errors returned by the Subsonic API payload.
class SubsonicApiException extends SubsonicException {
  const new({required this.code, required String message, this.retryAt})
    : super(message);

  final int? code;
  final DateTime? retryAt;
}

/// Authentication failed (`error.code == 40`).
class SubsonicAuthException extends SubsonicApiException {
  const new({required super.message}) : super(code: 40);
}

/// Token authentication is unsupported (`error.code == 41`).
class SubsonicTokenAuthUnsupportedException extends SubsonicApiException {
  const new({required super.message}) : super(code: 41);
}

/// Legacy authentication would expose a reversible password over HTTP.
class SubsonicInsecureLegacyAuthException extends SubsonicApiException {
  const new()
    : super(
        code: 41,
        message: 'This server requires legacy authentication. Use HTTPS to protect your password.',
      );
}

/// Authenticated user has insufficient permissions (`error.code == 50`).
class SubsonicForbiddenException extends SubsonicApiException {
  const new({required super.message}) : super(code: 50);
}

/// Resource does not exist (`error.code == 70`).
class SubsonicNotFoundException extends SubsonicApiException {
  const new({required super.message}) : super(code: 70);
}

/// Catch-all Subsonic API error.
class SubsonicGenericException extends SubsonicApiException {
  const new({required super.message, super.code, super.retryAt});
}

/// Transport-layer connectivity failure (DNS, timeout, etc.).
class SubsonicConnectionException extends SubsonicException {
  const new(super.message);
}

class SubsonicSyncLimitException extends SubsonicException {
  const new(this.reason) : super('Sync paused at its execution limit.');
  final String reason;
}

/// A successful envelope did not contain a trustworthy scoped snapshot.
class SubsonicIncompleteResponseException extends SubsonicException {
  const new(super.message, {this.isConflictingSnapshot = false});

  /// Identity or membership conflicts still require catalog verification.
  final bool isConflictingSnapshot;
}

/// A Subsonic response exceeded the configured byte budget.
class SubsonicResponseBudgetExceededException extends SubsonicException {
  const new({required this.maxBytes, required this.observedBytes})
    : super(
        'Response exceeded sync byte budget '
        '($observedBytes > $maxBytes).',
      );

  final int maxBytes;
  final int observedBytes;
}

/// Lyrics endpoint is not supported by the connected server.
class LyricsUnsupportedException implements Exception {
  const new([this.message = 'Lyrics not supported']);

  final String message;

  @override
  String toString() => message;
}

/// Network or transport error while fetching lyrics.
class LyricsNetworkException implements Exception {
  const new([this.message = 'Could not load lyrics']);

  final String message;

  @override
  String toString() => message;
}

SubsonicApiException mapSubsonicApiError({int? code, String? message}) {
  final resolvedMessage = message == null || message.isEmpty
      ? 'Unknown Subsonic API error.'
      : message;

  return switch (code) {
    40 => SubsonicAuthException(message: resolvedMessage),
    41 => SubsonicTokenAuthUnsupportedException(message: resolvedMessage),
    50 => SubsonicForbiddenException(message: resolvedMessage),
    70 => SubsonicNotFoundException(message: resolvedMessage),
    _ => SubsonicGenericException(code: code, message: resolvedMessage),
  };
}

/// Bytes from the start of a media payload that
/// [looksLikeSubsonicErrorDocument] inspects.
const int subsonicErrorDocumentProbeBytes = 256;

/// True when [head], the start of a downloaded media payload, reads as a
/// Subsonic error envelope. Navidrome answers some failed media requests (a
/// missing song or cover) with HTTP 200 and this document instead of an error
/// status, so a status check alone would keep the document as media.
bool looksLikeSubsonicErrorDocument(List<int> head) {
  final sample = String.fromCharCodes(
    head.take(subsonicErrorDocumentProbeBytes),
  );
  return sample.contains('subsonic-response') && sample.contains('failed');
}
