import 'dart:io';

import 'package:path/path.dart' as p;

/// macOS self-update helpers shared by the updater and app startup.
///
/// The updater script (`UpdateScripts.writeMacosScript`) writes `pending` to
/// [handshakeFileName] in the app support directory, opens the new app, and
/// keeps the previous app as `<App>.app.backup` until the new one rewrites the
/// file as `started`. A fresh file therefore means "an update script is
/// running": leave the backup alone and confirm the launch.
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

  /// Called at app startup. Confirms the launch to a waiting update script,
  /// or, when none is waiting, removes a stale `<App>.app.backup` that sits
  /// next to [bundlePath].
  static Future<void> startupHandshake({
    required String supportDir,
    required String bundlePath,
    DateTime? now,
  }) async {
    final file = File(p.join(supportDir, handshakeFileName));
    if (file.existsSync()) {
      final age = (now ?? DateTime.now()).difference(file.statSync().modified);
      if (age < handshakeMaxAge) {
        if (file.readAsStringSync().trim() == 'pending') {
          file.writeAsStringSync('started');
        }
        return;
      }
      file.deleteSync();
    }
    final backup = Directory('$bundlePath.backup');
    if (backup.existsSync()) await backup.delete(recursive: true);
  }
}
