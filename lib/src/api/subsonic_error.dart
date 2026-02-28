/// Base class for Subsonic domain and transport exceptions.
sealed class SubsonicException implements Exception {
  const SubsonicException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Base class for errors returned by the Subsonic API payload.
class SubsonicApiException extends SubsonicException {
  const SubsonicApiException({required this.code, required String message})
    : super(message);

  final int? code;
}

/// Authentication failed (`error.code == 40`).
class SubsonicAuthException extends SubsonicApiException {
  const SubsonicAuthException({required super.message}) : super(code: 40);
}

/// Authenticated user has insufficient permissions (`error.code == 50`).
class SubsonicForbiddenException extends SubsonicApiException {
  const SubsonicForbiddenException({required super.message}) : super(code: 50);
}

/// Resource does not exist (`error.code == 70`).
class SubsonicNotFoundException extends SubsonicApiException {
  const SubsonicNotFoundException({required super.message}) : super(code: 70);
}

/// Catch-all Subsonic API error.
class SubsonicGenericException extends SubsonicApiException {
  const SubsonicGenericException({required super.message, super.code});
}

/// Transport-layer connectivity failure (DNS, timeout, etc.).
class SubsonicConnectionException extends SubsonicException {
  const SubsonicConnectionException(super.message);
}

/// Lyrics endpoint is not supported by the connected server.
class LyricsUnsupportedException implements Exception {
  const LyricsUnsupportedException([this.message = 'Lyrics not supported']);

  final String message;

  @override
  String toString() => message;
}

/// Network or transport error while fetching lyrics.
class LyricsNetworkException implements Exception {
  const LyricsNetworkException([this.message = 'Could not load lyrics']);

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
    50 => SubsonicForbiddenException(message: resolvedMessage),
    70 => SubsonicNotFoundException(message: resolvedMessage),
    _ => SubsonicGenericException(code: code, message: resolvedMessage),
  };
}
