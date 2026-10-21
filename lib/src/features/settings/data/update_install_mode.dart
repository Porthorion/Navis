import 'dart:io';

import 'package:path/path.dart' as p;

/// Describes how the running Navis binary was installed, which determines
/// which release asset to download and how to apply the update.
enum UpdateInstallMode {
  /// Android APK, installed via system package manager.
  androidApk,

  /// Windows, installed via the Inno Setup installer (navis-...-windows-installer.exe).
  /// Detected by the presence of `unins000.exe` alongside the running exe.
  windowsInstaller,

  /// Windows, distributed as a portable zip bundle (navis-...-windows.zip).
  windowsPortable,

  /// macOS .app bundle distributed as a zip (navis-...-macos.zip).
  macosBundle,

  /// Linux, owned by a Debian package under /opt/navis.
  linuxDeb,

  /// Linux, owned by an RPM package under /opt/navis.
  linuxRpm,

  /// Linux, installed under /opt/navis with another or unknown package owner.
  linuxPackageManaged,

  /// Linux, distributed as a portable tar.gz bundle.
  linuxPortable,
}

typedef ProcessRunSync = ProcessResult Function(String exe, List<String> args);

final _detectedInstallMode = _detectInstallMode(Process.runSync);

/// Returns the [UpdateInstallMode] for the currently running process.
///
/// Uses the resolved executable path and filesystem heuristics — no user
/// configuration is required.
UpdateInstallMode detectInstallMode({ProcessRunSync? runSync}) =>
    runSync == null ? _detectedInstallMode : _detectInstallMode(runSync);

UpdateInstallMode _detectInstallMode(ProcessRunSync runSync) {
  if (Platform.isAndroid) return UpdateInstallMode.androidApk;
  if (Platform.isMacOS) return UpdateInstallMode.macosBundle;

  if (Platform.isWindows) {
    // The Inno Setup installer places unins000.exe in the install directory.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final uninsFile = File(p.join(exeDir, 'unins000.exe'));
    return uninsFile.existsSync()
        ? UpdateInstallMode.windowsInstaller
        : UpdateInstallMode.windowsPortable;
  }

  if (Platform.isLinux) {
    return detectLinuxPackageMode(Platform.resolvedExecutable, runSync);
  }

  // iOS — updates managed by the App Store; this code path is unreachable in
  // practice, but satisfies the type system.
  return UpdateInstallMode.androidApk;
}

/// Returns true for any desktop (non-mobile) install mode.
bool isDesktopInstallMode(UpdateInstallMode mode) {
  return mode != UpdateInstallMode.androidApk;
}

/// Detects package ownership of the canonical Linux installation binary.
UpdateInstallMode detectLinuxPackageMode(String exePath, ProcessRunSync run) {
  if (!p.posix.isWithin('/opt/navis', p.posix.normalize(exePath))) {
    return UpdateInstallMode.linuxPortable;
  }
  for (final (exe, args, mode) in [
    ('dpkg-query', ['-S', '/opt/navis/navis'], UpdateInstallMode.linuxDeb),
    ('rpm', ['-qf', '/opt/navis/navis'], UpdateInstallMode.linuxRpm),
  ]) {
    try {
      if (run(exe, args).exitCode == 0) return mode;
    } on ProcessException catch (_) {
      // The package manager is not installed on this distribution.
    }
  }
  return UpdateInstallMode.linuxPackageManaged;
}

/// Returns whether [mode] belongs to a Linux system package installation.
bool isLinuxSystemPackageMode(UpdateInstallMode mode) =>
    mode == UpdateInstallMode.linuxDeb ||
    mode == UpdateInstallMode.linuxRpm ||
    mode == UpdateInstallMode.linuxPackageManaged;
