import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/external_url.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';

class _Launcher extends UrlLauncherPlatform {
  @override
  LinkDelegate? get linkDelegate => null;

  final launched = <String>[];

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    expect(options.mode, PreferredLaunchMode.externalApplication);
    launched.add(url);
    return true;
  }
}

void main() {
  late _Launcher launcher;
  late UrlLauncherPlatform previous;
  setUp(() {
    previous = UrlLauncherPlatform.instance;
    launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
  });
  tearDown(() => UrlLauncherPlatform.instance = previous);

  test('rejects unsafe schemes before calling the platform', () async {
    for (final url in [
      'file:///tmp/evil.desktop',
      'search-ms:query=evil',
      'javascript:alert(1)',
      'intent://evil',
      'https:///no-host',
      'https://[invalid',
    ]) {
      expect(await launchExternalHttpUrl(url), isFalse);
    }
    expect(launcher.launched, isEmpty);
  });

  test('launches hosted HTTPS and HTTP', () async {
    for (final url in ['https://example.com/path', 'http://example.com/path']) {
      expect(await launchExternalHttpUrl(url), isTrue);
    }
    expect(launcher.launched, hasLength(2));
  });

  test('only UUID MusicBrainz identifiers can enter URL paths', () {
    expect(isMusicBrainzUuid('12345678-1234-1234-1234-123456789abc'), isTrue);
    for (final id in [null, '', '../evil', '1234?query=evil']) {
      expect(isMusicBrainzUuid(id), isFalse);
    }
  });
}
