/// Parses a three-part release version, ignoring a build suffix (`+10403`)
/// and a label suffix such as the diagnostics builds' `-sidecar`.
///
/// Whitespace and a leading `v` are accepted. [allowExtraParts] preserves
/// the updater's acceptance of additional dot components.
/// Returns null for a missing or malformed version.
List<int>? parseSemver(String? version, {bool allowExtraParts = false}) {
  if (version == null) return null;
  var value = version.trim();
  if (value.startsWith('v')) value = value.substring(1);
  final parts = value.split('+').first.split('-').first.split('.');
  if (parts.length < 3 || (!allowExtraParts && parts.length != 3)) return null;
  final numbers = parts.take(3).map(int.tryParse).toList();
  if (numbers.any((n) => n == null)) return null;
  return numbers.cast<int>();
}

/// Compares versions returned by [parseSemver] in release order.
int compareSemver(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    final diff = a[i] - b[i];
    if (diff != 0) return diff;
  }
  return 0;
}
