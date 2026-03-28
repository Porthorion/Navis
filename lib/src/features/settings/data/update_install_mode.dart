import 'dart:io';

/// Describes how the running Navis binary was installed, which determines
/// which Forgejo release asset to download and how to apply the update.
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

  /// Linux, installed via the .deb package (running under /opt/navis).
  linuxDeb,

  /// Linux, distributed as a portable tar.gz bundle.
  linuxPortable,
}

/// Returns the [UpdateInstallMode] for the currently running process.
///
/// Uses the resolved executable path and filesystem heuristics — no user
/// configuration is required.
UpdateInstallMode detectInstallMode() {
  if (Platform.isAndroid) return UpdateInstallMode.androidApk;
  if (Platform.isMacOS) return UpdateInstallMode.macosBundle;

  if (Platform.isWindows) {
    // The Inno Setup installer places unins000.exe in the install directory.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final uninsFile = File('$exeDir${Platform.pathSeparator}unins000.exe');
    return uninsFile.existsSync()
        ? UpdateInstallMode.windowsInstaller
        : UpdateInstallMode.windowsPortable;
  }

  if (Platform.isLinux) {
    // The .deb package installs the binary to /opt/navis/navis.
    final exePath = Platform.resolvedExecutable;
    if (exePath.startsWith('/opt/navis')) {
      return UpdateInstallMode.linuxDeb;
    }
    return UpdateInstallMode.linuxPortable;
  }

  // iOS — updates managed by the App Store; this code path is unreachable in
  // practice, but satisfies the type system.
  return UpdateInstallMode.androidApk;
}

/// Returns true for any desktop (non-mobile) install mode.
bool isDesktopInstallMode(UpdateInstallMode mode) {
  return mode != UpdateInstallMode.androidApk;
}
