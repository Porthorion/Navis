import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/icy_property_source_io.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';

class _NativePlayer extends Mock implements NativePlayer;

void main() {
  test('reads and observes through the pinned NativePlayer API', () async {
    final native = _NativePlayer();
    final source = NativeIcyPropertySource(native);
    Future<void> listener(String value) async {}
    when(() => native.observeProperty('metadata', listener))
        .thenAnswer((_) async {});
    when(
      () => native.getProperty(
        'metadata/by-key/icy-title',
        waitForInitialization: false,
      ),
    ).thenAnswer((_) async => 'Artist - Song');
    when(() => native.unobserveProperty('metadata')).thenAnswer((_) async {});
    await source.observe('metadata', listener);
    expect(await source.read('metadata/by-key/icy-title'), 'Artist - Song');
    await source.unobserve('metadata');
    verifyInOrder([
      () => native.observeProperty('metadata', listener),
      () => native.getProperty(
        'metadata/by-key/icy-title',
        waitForInitialization: false,
      ),
      () => native.unobserveProperty('metadata'),
    ]);
  });

  test('reads properties without waiting for playback readiness', () async {
    final native = _NativePlayer();
    final source = NativeIcyPropertySource(native);
    when(() => native.getProperty('volume', waitForInitialization: false))
        .thenAnswer((_) async => '37');
    expect(await source.read('volume'), '37');
    verify(() => native.getProperty('volume', waitForInitialization: false))
        .called(1);
  });

  test('non-native players have no ICY properties', () async {
    final source = NativeIcyPropertySource(null);
    await source.observe('metadata', (_) async {});
    expect(await source.read('metadata/by-key/icy-title'), isEmpty);
    await source.unobserve('metadata');
  });
}
