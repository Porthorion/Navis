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

  group('desktopStreamTlsVerify', () {
    test('Linux, Windows and macOS verify with the system store', () {
      for (final platform in ['linux', 'windows', 'macos']) {
        expect(
          desktopStreamTlsVerify(
            isLinux: platform == 'linux',
            isWindows: platform == 'windows',
            isMacOS: platform == 'macos',
          ),
          isTrue,
          reason: platform,
        );
      }
    });

    test('other platforms leave verification to their own audio stack', () {
      expect(
        desktopStreamTlsVerify(
          isLinux: false,
          isWindows: false,
          isMacOS: false,
        ),
        isFalse,
      );
    });
  });

  group('configureDesktopStreamTls', () {
    tearDown(() => JustAudioMediaKit.tlsVerify = false);

    test('macOS hands verification to the adapter, with no CA file', () {
      configureDesktopStreamTls(
        isLinux: false,
        isWindows: false,
        isMacOS: true,
      );
      expect(JustAudioMediaKit.tlsVerify, isTrue);
    });

    test('Linux hands over verification', () {
      configureDesktopStreamTls(
        isLinux: true,
        isWindows: false,
        isMacOS: false,
      );
      expect(JustAudioMediaKit.tlsVerify, isTrue);
    });
  });
}
