#!/usr/bin/env dart

// Outputs the Markdown release notes for a given version from the app's
// changelog (lib/src/features/changelog/changelog_data.dart), which is the
// single source of truth. Used by release.sh to populate the Forgejo release
// body.
//
// Usage:
//   dart tool/generate_release_notes.dart v0.3.0
//
// Exit codes:
//   0 – success, markdown written to stdout
//   1 – missing or invalid version argument
//   2 – no changelog entry found for the requested version

// ignore_for_file: avoid_print // CLI tool — stdout is the intended output channel

import 'dart:io';

import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/release_notes_markdown.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart tool/generate_release_notes.dart <version>');
    stderr.writeln('Example: dart tool/generate_release_notes.dart v0.3.0');
    exit(1);
  }

  // Strip leading 'v' to normalise input.
  var requested = args[0].trim();
  if (requested.startsWith('v')) requested = requested.substring(1);

  final match = changelogs.where((c) => c.version == requested).firstOrNull;
  if (match == null) {
    stderr.writeln(
      'No changelog found for version $requested. Add an entry to '
      'lib/src/features/changelog/changelog_data.dart before releasing.',
    );
    exit(2);
  }

  print(renderReleaseNotes(match));
}
