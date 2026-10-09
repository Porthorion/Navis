import 'dart:io';

import 'package:path/path.dart' as p;

/// Finds the Linux bundle's audio library, or leaves system lookup in place.
String? bundledLibmpvPath({
  bool? isLinux,
  String? executable,
  bool Function(String)? fileExists,
}) {
  if (!(isLinux ?? Platform.isLinux)) return null;
  final candidate = p.posix.join(
    p.posix.dirname(executable ?? Platform.resolvedExecutable),
    'lib',
    'libmpv.so.2',
  );
  return (fileExists ?? (path) => File(path).existsSync())(candidate)
      ? candidate
      : null;
}
