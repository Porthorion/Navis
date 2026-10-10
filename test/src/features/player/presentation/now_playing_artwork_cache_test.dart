import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

Future<ImageProvider<Object>> _cover() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 96, 96),
    Paint()..color = const Color(0xFF192B82),
  );
  canvas.drawCircle(
    const Offset(25, 25),
    27,
    Paint()..color = const Color(0xFFF7668C),
  );
  canvas.drawCircle(
    const Offset(70, 65),
    35,
    Paint()..color = const Color(0xFFFFC848),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 80, 96, 16),
    Paint()..color = const Color(0xFF2BA7AE),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(96, 96);
  picture.dispose();
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  return MemoryImage(Uint8List.sublistView(bytes));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('coalesces concurrent preparation, hits LRU, evicts and releases owned handles', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final cache = container.read(nowPlayingArtworkCacheProvider);
    final source = await _cover();
    final pair = await Future.wait([
      cache.acquire('a', source, ImageConfiguration.empty),
      cache.acquire('a', source, ImageConfiguration.empty),
    ]);
    expect(cache.debugRenderCount, 1);
    expect(cache.debugHitCount, 1);
    expect(pair[0].image.isCloneOf(pair[1].image), isTrue);
    expect(pair[0].average, isNotNull);
    final original = cache.debugCachedImage('a')!;
    for (final key in ['b', 'c', 'd']) {
      await cache.prewarm(key, source, ImageConfiguration.empty);
    }
    final hit = await cache.acquire('a', source, ImageConfiguration.empty);
    hit.image.dispose();
    final evicted = cache.debugCachedImage('b')!;
    await cache.prewarm('e', source, ImageConfiguration.empty);
    expect(evicted.debugDisposed, isTrue);
    expect(original.debugDisposed, isFalse);
    await cache.prewarm('f', source, ImageConfiguration.empty);
    await cache.prewarm('g', source, ImageConfiguration.empty);
    await cache.prewarm('h', source, ImageConfiguration.empty);
    expect(original.debugDisposed, isTrue);
    expect(pair[0].image.debugDisposed, isFalse);
    expect(await pair[0].image.toByteData(), isNotNull);
    for (final entry in pair) {
      entry.image.dispose();
    }
    final last = cache.debugCachedImage('h')!;
    container.dispose();
    expect(last.debugDisposed, isTrue);
  });

  test('failure is uncached and prewarm failures remain best effort', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final cache = container.read(nowPlayingArtworkCacheProvider);
    final invalid = MemoryImage(Uint8List.fromList([0, 1, 2]));
    await expectLater(
      cache.acquire('bad', invalid, ImageConfiguration.empty),
      throwsA(isA<Exception>()),
    );
    expect(cache.debugCachedImage('bad'), isNull);
    await cache.prewarm('bad', invalid, ImageConfiguration.empty);
    final repaired = await cache.acquire(
      'bad',
      await _cover(),
      ImageConfiguration.empty,
    );
    expect(cache.debugRenderCount, 1);
    repaired.image.dispose();
  });

  testWidgets('provider disposal cancels outstanding decode listeners', (
    tester,
  ) async {
    final source = _PendingImage();
    final container = ProviderContainer();
    final cache = container.read(nowPlayingArtworkCacheProvider);
    final future = cache.acquire('pending', source, ImageConfiguration.empty);
    final assertion = expectLater(future, throwsStateError);
    await tester.pump();
    expect(source.completer.listeners, hasLength(1));
    container.dispose();
    await assertion;
    expect(source.completer.listeners, isEmpty);
    expect(cache.debugRenderCount, 0);
  });

  testWidgets('prewarmed player queue and lyrics share one static blur', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final cache = container.read(nowPlayingArtworkCacheProvider);
    final source = (await tester.runAsync(_cover))!;
    await tester.runAsync(
      () => cache.prewarm('shared', source, ImageConfiguration.empty),
    );
    Widget layer({required bool lyrics}) => NowPlayingArtworkBackground(
      imageKey: 'shared',
      image: source,
      colorStyle: NavisColorStyleData.neutralDark,
      surfaceColor: const Color(0xFF101418),
      onSurfaceColor: Colors.white,
      minVeilAlpha: lyrics ? 0.6 : null,
      fadeDuration: Duration.zero,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Row(
              children: [
                for (final lyrics in [false, false, true])
                  Expanded(child: layer(lyrics: lyrics)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(RawImage), findsNWidgets(3));
    expect(find.byType(ImageFiltered), findsNothing);
    for (final veil in tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    )) {
      expect(veil.duration, Duration.zero);
    }
    expect(cache.debugRenderCount, 1);
    expect(cache.debugHitCount, 3);
    final images = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
    expect(images[0].image!.isCloneOf(images[2].image!), isTrue);
  });

  testWidgets('soft colourful artwork layer golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final source = (await tester.runAsync(_cover))!;
    await tester.runAsync(
      () => container
          .read(nowPlayingArtworkCacheProvider)
          .prewarm('golden', source, ImageConfiguration.empty),
    );
    const boundary = ValueKey<String>('blurredLayer');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: boundary,
              child: SizedBox(
                width: 390,
                height: 844,
                child: NowPlayingArtworkBackground(
                  imageKey: 'golden',
                  image: source,
                  colorStyle: NavisColorStyleData.neutralDark,
                  surfaceColor: const Color(0xFF101418),
                  onSurfaceColor: Colors.white,
                  fadeDuration: Duration.zero,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsOneWidget);
    await expectLater(
      find.byKey(boundary),
      matchesGoldenFile('goldens/now_playing_static_artwork_blur.png'),
    );
  });
}

class _PendingImage extends ImageProvider<_PendingImage> {
  final completer = _PendingCompleter();
  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) async =>
      this;
  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    _PendingImage key,
    ImageErrorListener handleError,
  ) => stream.setCompleter(completer);
}

class _PendingCompleter extends ImageStreamCompleter {
  final listeners = <ImageStreamListener>[];
  @override
  void addListener(ImageStreamListener listener) => listeners.add(listener);
  @override
  void removeListener(ImageStreamListener listener) =>
      listeners.remove(listener);
}
