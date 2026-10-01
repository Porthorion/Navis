import 'package:navis/src/features/changelog/changelog_data.dart';

/// Renders [version] as the Markdown body of its Forgejo release.
///
/// Older app versions show this body in their update dialog, so it sticks to
/// plain headings and lists. The release icon is app-only and not emitted.
String renderReleaseNotes(ChangelogVersion version) {
  final buf = StringBuffer();
  final codename = version.codename;
  buf.writeln(
    codename == null
        ? "## What's New in Navis v${version.version}"
        : "## What's New in Navis v${version.version} “$codename”",
  );

  final summary = version.summary;
  if (summary != null) {
    buf
      ..writeln()
      ..writeln(summary);
  }

  if (version.highlights.isNotEmpty) {
    buf
      ..writeln()
      ..writeln('### Highlights')
      ..writeln();
    for (final highlight in version.highlights) {
      buf.writeln('- **${highlight.title}:** ${highlight.body}');
    }
  }

  for (final (type, heading) in const <(ChangelogEntryType, String)>[
    (ChangelogEntryType.newFeature, 'New'),
    (ChangelogEntryType.improvement, 'Improved'),
    (ChangelogEntryType.fix, 'Fixed'),
  ]) {
    final entries = version.entries.where((entry) => entry.type == type);
    if (entries.isEmpty) continue;
    buf
      ..writeln()
      ..writeln('### $heading')
      ..writeln();
    for (final entry in entries) {
      buf.writeln('- ${entry.text}');
    }
  }

  if (version.specialThanks.isNotEmpty) {
    buf
      ..writeln()
      ..writeln('## Special Thanks')
      ..writeln();
    for (final thankYou in version.specialThanks) {
      buf.writeln('- $thankYou');
    }
  }

  return buf.toString().trimRight();
}
