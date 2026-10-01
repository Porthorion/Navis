import 'dart:async';

/// Query parameters that authenticate a Subsonic or OpenSubsonic request.
///
/// A token and salt pair (`t`, `s`) can be replayed, `p` carries the password,
/// `apiKey` is OpenSubsonic API-key authentication, and `u` names the account.
const subsonicCredentialQueryParameters = {'u', 't', 's', 'p', 'apiKey'};

/// A credential parameter anywhere in free text, after a literal or
/// percent-encoded `?` or `&`, up to the next parameter, fragment, whitespace,
/// or quote.
final _credentialQueryParameter = RegExp(
  '((?:[?&]|%3F|%26)'
  '(?:${subsonicCredentialQueryParameters.map(RegExp.escape).join('|')})'
  r'''(?:=|%3D))(?:(?!%26)[^&#\s"'<>])+''',
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
