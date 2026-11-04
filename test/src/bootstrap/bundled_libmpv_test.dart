import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:navis/src/bootstrap/bundled_libmpv.dart';

void main() {
  test('Linux uses the library beside the resolved executable', () {
    String? checked;
    expect(
      bundledLibmpvPath(
        isLinux: true,
        executable: '/opt/Navis bundle/navis',
        fileExists: (path) {
          checked = path;
          return true;
        },
      ),
      '/opt/Navis bundle/lib/libmpv.so.2',
    );
    expect(checked, '/opt/Navis bundle/lib/libmpv.so.2');
  });

  test('Linux falls back to system lookup when the bundle is absent', () {
    expect(
      bundledLibmpvPath(
        isLinux: true,
        executable: '/dev/navis',
        fileExists: (_) => false,
      ),
      isNull,
    );
  });

  test('other platforms never inspect or override their audio library', () {
    expect(
      bundledLibmpvPath(
        isLinux: false,
        fileExists: (_) => throw StateError('Must not inspect a Linux path'),
      ),
      isNull,
    );
  });

  group('desktopStreamTls', () {
    test("Linux and Windows verify with libmpv's own store", () {
      for (final platform in ['linux', 'windows']) {
        final tls = desktopStreamTls(
          isLinux: platform == 'linux',
          isWindows: platform == 'windows',
          isMacOS: false,
          fileExists: (_) => throw StateError('Must not inspect a CA file'),
        );
        expect(tls.verify, isTrue, reason: platform);
        expect(tls.caFile, isNull, reason: platform);
      }
    });

    test('macOS verifies against the system CA bundle file', () {
      final tls = desktopStreamTls(
        isLinux: false,
        isWindows: false,
        isMacOS: true,
        fileExists: (path) => path == '/etc/ssl/cert.pem',
      );
      expect(tls.verify, isTrue);
      expect(tls.caFile, '/etc/ssl/cert.pem');
    });

    test('macOS without the bundle stays off and says so', () {
      var warned = false;
      final tls = desktopStreamTls(
        isLinux: false,
        isWindows: false,
        isMacOS: true,
        fileExists: (_) => false,
        onMissingCaFile: () => warned = true,
      );
      expect(tls.verify, isFalse);
      expect(tls.caFile, isNull);
      expect(warned, isTrue);
    });
  });

  group('configureDesktopStreamTls', () {
    tearDown(() {
      JustAudioMediaKit.tlsVerify = false;
      JustAudioMediaKit.tlsCaFile = null;
    });

    test('macOS hands verification and the CA file to the adapter', () {
      configureDesktopStreamTls(
        isLinux: false,
        isWindows: false,
        isMacOS: true,
        fileExists: (_) => true,
      );
      expect(JustAudioMediaKit.tlsVerify, isTrue);
      expect(JustAudioMediaKit.tlsCaFile, '/etc/ssl/cert.pem');
    });

    test('Linux hands over verification without a CA file', () {
      configureDesktopStreamTls(
        isLinux: true,
        isWindows: false,
        isMacOS: false,
      );
      expect(JustAudioMediaKit.tlsVerify, isTrue);
      expect(JustAudioMediaKit.tlsCaFile, isNull);
    });
  });
}
