import 'dart:io';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
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

/// Whether the desktop libmpv checks stream certificates. Every desktop
/// bundle (Linux, Windows, macOS) is Navis's own build whose TLS reads the
/// system certificate store, so there is no CA file to supply.
bool desktopStreamTlsVerify({bool? isLinux, bool? isWindows, bool? isMacOS}) =>
    (isLinux ?? Platform.isLinux) ||
    (isWindows ?? Platform.isWindows) ||
    (isMacOS ?? Platform.isMacOS);

/// Applies [desktopStreamTlsVerify] to the desktop libmpv adapter.
void configureDesktopStreamTls({
  bool? isLinux,
  bool? isWindows,
  bool? isMacOS,
}) {
  JustAudioMediaKit.tlsVerify = desktopStreamTlsVerify(
    isLinux: isLinux,
    isWindows: isWindows,
    isMacOS: isMacOS,
  );
}
