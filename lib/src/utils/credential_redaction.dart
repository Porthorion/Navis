import 'dart:async';

/// Query parameters that authenticate a Subsonic or OpenSubsonic request.
///
/// A token and salt pair (`t`, `s`) can be replayed, `p` carries the password,
/// `apiKey` is OpenSubsonic API-key authentication, and `u` names the account.
const subsonicCredentialQueryParameters = {
  'u',
  't',
  's',
  'p',
  'apiKey',
  'api_key',
};

/// Whether [uri] carries a Subsonic credential query parameter, and so must
/// not be handed to another process (media sessions, MPRIS, SMTC).
bool uriCarriesCredentials(Uri uri) {
  final keys = uri.queryParameters.keys.map((key) => key.toLowerCase());
  return keys.any(
    (key) => subsonicCredentialQueryParameters.any(
      (parameter) => parameter.toLowerCase() == key,
    ),
  );
}

/// A credential parameter anywhere in free text, after a literal, HTML-escaped
/// (`&amp;`), percent-encoded or double percent-encoded `?` or `&`, up to the
/// next parameter, fragment, whitespace, or quote.
final _credentialQueryParameter = RegExp(
  '((?:[?&]|&amp;|%3F|%26|%253F|%2526)'
  '(?:${subsonicCredentialQueryParameters.map(RegExp.escape).join('|')})'
  r'''(?:=|%3D|%253D))(?:(?!%26|%2526)[^&#\s"'<>])+''',
  caseSensitive: false,
);

/// Replaces the value of every Subsonic credential query parameter in [text]
/// with `REDACTED`, leaving the rest of the text, including other parameters
/// such as the song `id`, unchanged.
String redactCredentialQueryParameters(String text) =>
    text.replaceAllMapped(_credentialQueryParameter, (m) => '${m[1]}REDACTED');

/// Runs [body] in a zone whose `print` passes every line through
/// [redactCredentialQueryParameters] before the parent zone writes it.
///
/// Dependencies print diagnostics that Navis cannot reformat at the source:
/// mpv's errors quote the full stream URL, for example. Everything that
/// prints from this zone, including `debugPrint` and `AppLogger` output, is
/// covered in every build mode.
R runWithCredentialRedactedPrint<R>(R Function() body) => runZoned(
  body,
  zoneSpecification: ZoneSpecification(
    print: (self, parent, zone, line) =>
        parent.print(zone, redactCredentialQueryParameters(line)),
  ),
);

/// Reports an error that no zone or `Future` handled, with credential query
/// parameters redacted, and marks it handled.
///
/// Install it as `PlatformDispatcher.instance.onError`. The line keeps the
/// engine's `Unhandled Exception:` wording, which diagnostics runs search
/// their logs for. Without it the engine
/// prints such errors itself, outside every zone's `print`, so an
/// `HttpException` or `DioException` that quotes a stream or API URL would
/// reach the terminal and system log with the account token.
bool reportUncaughtErrorRedacted(Object error, StackTrace stackTrace) {
  print(
    redactCredentialQueryParameters('Unhandled Exception: $error\n$stackTrace'),
  );
  return true;
}
