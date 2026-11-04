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

/// Where macOS's libmpv finds trusted roots. Its bundled Mbed TLS cannot read
/// the system store, so verification needs this file; roots that exist only in
/// the keychain (a private CA) are not trusted for streams.
const macosCaFile = '/etc/ssl/cert.pem';

/// Stream certificate checking for the desktop libmpv: `verify` and, on macOS,
/// the CA bundle `caFile`. macOS stays unverified, with [onMissingCaFile]
/// called, when the bundle is absent, because verifying with no roots would
/// refuse every stream.
({bool verify, String? caFile}) desktopStreamTls({
  bool? isLinux,
  bool? isWindows,
  bool? isMacOS,
  bool Function(String)? fileExists,
  void Function()? onMissingCaFile,
}) {
  if (isMacOS ?? Platform.isMacOS) {
    if ((fileExists ?? (path) => File(path).existsSync())(macosCaFile)) {
      return (verify: true, caFile: macosCaFile);
    }
    onMissingCaFile?.call();
    return (verify: false, caFile: null);
  }
  return (
    verify: (isLinux ?? Platform.isLinux) || (isWindows ?? Platform.isWindows),
    caFile: null,
  );
}

/// Applies [desktopStreamTls] to the desktop libmpv adapter.
void configureDesktopStreamTls({
  bool? isLinux,
  bool? isWindows,
  bool? isMacOS,
  bool Function(String)? fileExists,
  void Function()? onMissingCaFile,
}) {
  final tls = desktopStreamTls(
    isLinux: isLinux,
    isWindows: isWindows,
    isMacOS: isMacOS,
    fileExists: fileExists,
    onMissingCaFile: onMissingCaFile,
  );
  JustAudioMediaKit.tlsVerify = tls.verify;
  JustAudioMediaKit.tlsCaFile = tls.caFile;
}
