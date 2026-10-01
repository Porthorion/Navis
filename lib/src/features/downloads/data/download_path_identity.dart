import 'dart:io';

import 'package:path/path.dart' as p;

/// How Navis names and compares files inside one download folder.
///
/// The same file can be reached through different spellings of the folder:
/// the path the user chose, the same folder through a symlink, junction or
/// mapped drive, and on Windows any mix of letter case. Stored download
/// paths use the chosen spelling while a scan walks the resolved folder, so
/// every comparison goes through a *key*: the file's path relative to the
/// folder, with `/` separators on every platform. Keys compare
/// case-insensitively on Windows only.
class DownloadRootIdentity {
  new _(this.rootPath, this.canonicalRoot, this._context);

  /// [rootPath] as given and its resolved form; [context] is for tests.
  factory of(String rootPath, {String? canonicalRoot, p.Context? context}) {
    final paths = context ?? p.context;
    final root = paths.normalize(rootPath);
    return DownloadRootIdentity._(
      root,
      canonicalRoot == null ? root : paths.normalize(canonicalRoot),
      paths,
    );
  }

  /// Resolves [rootPath] once; a folder that cannot be resolved is used as
  /// given.
  static Future<DownloadRootIdentity> resolve(String rootPath) async {
    String? canonical;
    try {
      canonical = await Directory(rootPath).resolveSymbolicLinks();
    } on FileSystemException {
      canonical = null;
    }
    return DownloadRootIdentity.of(rootPath, canonicalRoot: canonical);
  }

  /// The folder as configured.
  final String rootPath;

  /// The folder with links resolved; scans walk this one.
  final String canonicalRoot;
  final p.Context _context;

  bool get _foldsCase => _context.style == p.Style.windows;

  /// The key of [path], or null when it is not inside the folder.
  String? keyFor(String path) {
    final normalized = _context.normalize(path);
    for (final root in <String>{canonicalRoot, rootPath}) {
      if (_context.isWithin(root, normalized)) {
        return _context
            .split(_context.relative(normalized, from: root))
            .join('/');
      }
    }
    return null;
  }

  /// The file for [key], inside [canonicalRoot].
  String pathFor(String key) =>
      _context.joinAll(<String>[canonicalRoot, ...key.split('/')]);

  /// [key] in the form used for lookups: case-folded on Windows. Also
  /// accepts keys written by older Navis builds with `\` separators.
  String lookupKey(String key) {
    final posix = key.replaceAll(r'\', '/').replaceFirst(RegExp(r'^\./'), '');
    return _foldsCase ? posix.toLowerCase() : posix;
  }
}
