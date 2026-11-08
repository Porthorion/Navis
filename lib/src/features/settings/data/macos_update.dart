import 'dart:io';

import 'package:path/path.dart' as p;

/// macOS self-update helpers shared by the updater and app startup.
///
/// The updater script (`UpdateScripts.writeMacosScript`) writes `pending` to
/// [handshakeFileName] in the app support directory, opens the new app, and
/// keeps the previous app as `<App>.app.backup` until the new app calls
/// [confirmLaunch] (after its first frame) to rewrite the file as `started`.
/// A fresh `pending` or `rollback` file therefore means "an update script is
/// running": leave the backup alone.
class MacosUpdate {
  static const handshakeFileName = 'navis-update-handshake';

  /// A script that was killed mid-update leaves its file behind; the whole
  /// handshake takes well under this long.
  static const handshakeMaxAge = Duration(minutes: 5);

  /// The `.app` ancestor of [executable], or null outside a bundle.
  static String? bundlePathOf(String executable) {
    var path = executable;
    while (path.isNotEmpty && !path.endsWith('.app')) {
      final parent = p.dirname(path);
      if (parent == path) return null;
      path = parent;
    }
    return path.endsWith('.app') ? path : null;
  }

  /// True for a quarantined download that macOS runs from a read-only
  /// `/AppTranslocation/` copy, or for an app run from a mounted disk image
  /// under `/Volumes/`. Neither can be replaced in place.
  static bool isTranslocatedOrOnVolume(String bundlePath) =>
      bundlePath.contains('/AppTranslocation/') ||
      bundlePath.startsWith('/Volumes/');

  /// Called at app startup. Removes a stale `<App>.app.backup` that sits next
  /// to [bundlePath], unless a fresh handshake says an update script is still
  /// working (`pending`, `rollback`). A handshake older than
  /// [handshakeMaxAge], or dated in the future by that much, was left by a
  /// killed script and is deleted.
  static Future<void> startupHandshake({
    required String supportDir,
    required String bundlePath,
    DateTime? now,
  }) async {
    final file = File(p.join(supportDir, handshakeFileName));
    if (file.existsSync()) {
      final age = (now ?? DateTime.now())
          .difference(file.statSync().modified)
          .abs();
      if (age < handshakeMaxAge) {
        if (file.readAsStringSync().trim() != 'started') return;
      } else {
        file.deleteSync();
      }
    }
    final backup = Directory('$bundlePath.backup');
    if (backup.existsSync()) await backup.delete(recursive: true);
  }

  /// Called once the app has rendered its first frame: answers a waiting
  /// update script's launch check. Does nothing unless the file says `pending`
  /// (a `rollback` is never overwritten).
  static void confirmLaunch(String supportDir) {
    final file = File(p.join(supportDir, handshakeFileName));
    if (file.existsSync() && file.readAsStringSync().trim() == 'pending') {
      file.writeAsStringSync('started');
    }
  }
}
