import 'dart:async';
import 'dart:convert';

/// Query parameters that authenticate a Subsonic or OpenSubsonic request.
///
/// A token and salt pair (`t`, `s`) can be replayed, `p` carries the password,
/// `apiKey` is OpenSubsonic API-key authentication, and `u` names the account.
/// This set also decides what [credentialFreeUri] strips from stored server
/// URLs and cache keys, so keep it to Subsonic's own parameters.
const subsonicCredentialQueryParameters = {
  'u',
  't',
  's',
  'p',
  'apiKey',
  'api_key',
};

/// Parameters redacted from free text (logs, diagnostics): the Subsonic set plus
/// the generic names a proxy, a redirect or an OAuth-style service puts on a
/// URL. Text redaction only; never used to rewrite a URL that is stored or sent.
const _textCredentialQueryParameters = {
  ...subsonicCredentialQueryParameters,
  'password',
  'token',
  'access_token',
  'refresh_token',
};

/// Whether [uri] carries URL user info or a Subsonic credential parameter and must
/// not be handed to another process (media sessions, MPRIS, SMTC).
bool uriCarriesCredentials(Uri uri) {
  if (uri.userInfo.isNotEmpty) return true;
  final keys = uri.queryParameters.keys.map((key) => key.toLowerCase());
  return keys.any(
    (key) => subsonicCredentialQueryParameters.any(
      (parameter) => parameter.toLowerCase() == key,
    ),
  );
}

/// Removes credentials from a URI before it enters a persistent cache.
Uri credentialFreeUri(Uri uri) => uri.replace(
  userInfo: '',
  queryParameters: {
    for (final entry in uri.queryParametersAll.entries)
      if (!subsonicCredentialQueryParameters.any(
        (key) => key.toLowerCase() == entry.key.toLowerCase(),
      ))
        entry.key: entry.value,
  },
);

/// A credential parameter anywhere in free text, after a literal, HTML-escaped
/// (`&amp;`), percent-encoded or double percent-encoded `?` or `&`, up to the
/// next parameter, fragment, whitespace, or quote.
final _credentialQueryParameter = RegExp(
  '((?:[?&]|&amp;|%3F|%26|%253F|%2526)'
  '(?:${_textCredentialQueryParameters.map(RegExp.escape).join('|')})'
  r'''(?:=|%3D|%253D))(?:(?!%26|%2526)[^&#\s"'<>])+''',
  caseSensitive: false,
);

// Strip user info from URL authorities in logs, including multiple URLs and
// percent-encoded credentials. Do not consume paths, queries or HTML delimiters.
final _credentialUserInfo = RegExp(
  r'''((?:[a-z][a-z0-9+.-]*:)?//)[^/\s?#"'<>]*@''',
  caseSensitive: false,
);

// `Bearer <token>`, and the value (with an optional scheme such as `Basic`) of
// an `Authorization: ...` header or key, in logs, JSON and error text.
final _authorizationCredential = RegExp(
  r'''(\bBearer\s+)[A-Za-z0-9._~+/=-]+'''
  r'''|(\bAuthorization["']?\s*[:=]\s*["']?(?:[a-z]+\s+)?)[^\s"',;&]+''',
  caseSensitive: false,
);

/// Strips URL user info and replaces the value of every Subsonic credential query parameter in [text]
/// with `REDACTED`, leaving the rest of the text, including other parameters
/// such as the song `id`, unchanged.
String redactCredentialQueryParameters(String text) => text
    .replaceAllMapped(_credentialUserInfo, (m) => m[1]!)
    .replaceAllMapped(_credentialQueryParameter, (m) => '${m[1]}REDACTED')
    .replaceAllMapped(
      _authorizationCredential,
      (m) => '${m[1] ?? m[2]}REDACTED',
    );

// The scheme and authority of a URI in free text; the path and query stay.
final _uriAuthority = RegExp(
  // The lookbehind keeps the scan linear on long letter runs.
  r'''(?<![a-z0-9+.-])[a-z][a-z0-9+.-]*://[^/\s?#"'<>]+''',
  caseSensitive: false,
);

// A `SocketException`'s trailing ", address = host, port = 4533".
final _socketAddressAndPort = RegExp(r',?\s*(?:address|port) = [^\s,]+');

// `SocketException: Failed host lookup: 'nas.example.com'`, also in rows
// stored before redaction and for a redirect target's host.
final _failedHostLookup = RegExp("Failed host lookup: '[^']*'");

/// Replaces the server's address in [text] with `<server>`: the scheme and
/// authority of every URI, [host] (with a following `:port`) wherever it
/// appears, and a `SocketException`'s address and port. Everything else,
/// including the exception type, stays.
///
/// For a failure detail a user may paste into a public bug report, which
/// must not reveal their server.
String redactServerHost(String text, {String? host}) {
  var result = text
      .replaceAll(_uriAuthority, '<server>')
      .replaceAll(_socketAddressAndPort, '')
      .replaceAll(_failedHostLookup, "Failed host lookup: '<server>'");
  if (host != null && host.isNotEmpty) {
    result = result.replaceAll(
      RegExp(
        '(?<![a-z0-9.-])\\[?${RegExp.escape(host)}\\]?(?::\\d+)?(?![a-z0-9-])',
        caseSensitive: false,
      ),
      '<server>',
    );
  }
  return result;
}

/// [text] with percent-encoding undone (twice at most), so a URL quoted in
/// encoded form is redacted like a plain one; unchanged if it will not decode.
String _percentDecoded(String text) {
  var result = text;
  for (var i = 0; i < 2 && result.contains('%'); i++) {
    try {
      result = Uri.decodeFull(result);
    } on Object {
      break;
    }
  }
  return result;
}

/// Encodes [data] as indented JSON after redacting every String leaf with
/// [redactCredentialQueryParameters] and [redactServerHost], for diagnostics a
/// user pastes into a bug report. Leaves are redacted before encoding, never
/// the encoded text, so an escaped quote cannot break the JSON. Map keys are
/// redacted like leaves; a `DateTime` leaf becomes ISO 8601 and any other
/// non-JSON leaf its redacted `toString`.
String redactedDiagnosticsJson(Map<String, Object?> data, {String? host}) {
  String clean(String s) => redactServerHost(
    redactCredentialQueryParameters(_percentDecoded(s)),
    host: host,
  );
  Object? walk(Object? v) => switch (v) {
    String s => clean(s),
    Map<Object?, Object?> m => {
      for (final e in m.entries) clean('${e.key}'): walk(e.value),
    },
    Iterable<Object?> l => [for (final x in l) walk(x)],
    _ => v,
  };
  return JsonEncoder.withIndent(
    '  ',
    (o) => o is DateTime ? o.toIso8601String() : clean('$o'),
  ).convert(walk(data));
}

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
  // iOS cuts a single `print` off at about 1 KB, which can drop the tail of a
  // stack trace, so emit one line per call. Redact before splitting.
  final text = redactCredentialQueryParameters(
    'Unhandled Exception: $error\n$stackTrace',
  );
  const LineSplitter().convert(text).forEach(print);
  return true;
}
