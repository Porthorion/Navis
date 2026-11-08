/// Returns the canonical form for identity comparisons and profile keys.
///
/// Do not use this form to build request URLs.
String canonicalServerIdentityUrl(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return trimmed.replaceFirst(RegExp(r'/+$'), '');
  }
  final path = uri.path == '/' ? '' : uri.path.replaceFirst(RegExp(r'/+$'), '');
  final defaultPort =
      (uri.scheme.toLowerCase() == 'https' && uri.port == 443) ||
      (uri.scheme.toLowerCase() == 'http' && uri.port == 80);
  return Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    port: defaultPort ? null : (uri.hasPort ? uri.port : null),
    path: path,
  ).toString();
}
