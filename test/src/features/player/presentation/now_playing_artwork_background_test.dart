import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_scope.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

const _covers = <String, Color>{
  'bright yellow': Color(0xFFFFEB3B),
  'white': Color(0xFFFFFFFF),
  'black': Color(0xFF000000),
  'saturated red': Color(0xFFE00000),
};

Future<ImageProvider> _solid(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = color);
  final image = await recorder.endRecording().toImage(4, 4);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  return MemoryImage(Uint8List.view(bytes.buffer));
}

void main() {
  group('Adaptive Artwork veil keeps on-surface text readable', () {
    for (final style in NavisColorStyle.values) {
      for (final mode in <String>['light', 'dark', 'oled']) {
        final dark = mode != 'light';
        final oled = mode == 'oled';
        final scheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFF3F7F6F),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        final surface = oled ? Colors.black : scheme.surface;
        final onSurface = oled ? Colors.white : scheme.onSurface;
        final data = NavisColorStyleData(style: style, dark: dark, oled: oled);
        final (min, max) = data.nowPlayingArtworkVeilRange;
        _covers.forEach((name, cover) {
          test('${style.name} $mode over $name', () {
            final veil = nowPlayingAdaptiveVeil(
              colorStyle: data,
              surface: surface,
              onSurface: onSurface,
              average: cover,
            );
            expect(veil.a, inInclusiveRange(min, max + 0.001));
            expect(
              captionContrast(onSurface, Color.alphaBlend(veil, cover)),
              greaterThanOrEqualTo(kCaptionMinContrast),
            );
          });
        });
        test('${style.name} $mode: black cover gets the minimum veil', () {
          final veil = nowPlayingAdaptiveVeil(
            colorStyle: data,
            surface: surface,
            onSurface: onSurface,
            average: Colors.black,
          );
          // Dark covers need little veil; a light theme's black cover needs
          // the most, so only dark modes sit at the floor.
          if (dark) expect(veil.a, closeTo(min, 0.0001));
        });
        test('${style.name} $mode: unknown average uses the fixed veil', () {
          expect(
            nowPlayingAdaptiveVeil(
              colorStyle: data,
              surface: surface,
              onSurface: onSurface,
              average: null,
            ),
            data.nowPlayingArtworkVeil(surface),
          );
        });
      }
    }

    test('ranges: dark 0.30-0.80, OLED 0.72-0.92, light 0.58-0.88', () {
      const style = NavisColorStyle.neutral;
      expect(
        const NavisColorStyleData(
          style: style,
          dark: true,
        ).nowPlayingArtworkVeilRange,
        (0.30, 0.80),
      );
      expect(
        const NavisColorStyleData(
          style: style,
          dark: true,
          oled: true,
        ).nowPlayingArtworkVeilRange,
        (0.72, 0.92),
      );
      expect(
        const NavisColorStyleData(
          style: style,
          dark: false,
        ).nowPlayingArtworkVeilRange,
        (0.58, 0.88),
      );
    });

    test('a dark cover shows more art than a bright one', () {
      const data = NavisColorStyleData(
        style: NavisColorStyle.neutral,
        dark: true,
      );
      double alpha(Color c) => nowPlayingAdaptiveVeil(
        colorStyle: data,
        surface: const Color(0xFF141218),
        onSurface: const Color(0xFFE6E0E9),
        average: c,
      ).a;
      expect(alpha(const Color(0xFF301000)), lessThan(alpha(Colors.white)));
    });

    test('the accent-coloured title also stays readable', () {
      const data = NavisColorStyleData(
        style: NavisColorStyle.pastel,
        dark: false,
      );
      const surface = Color(0xFFFFF4F0);
      const accent = Color(0xFFB0453A);
      const salmon = Color(0xFFE08A70);
      final veil = nowPlayingAdaptiveVeil(
        colorStyle: data,
        surface: surface,
        onSurface: const Color(0xFF2A1F1D),
        accent: accent,
        average: salmon,
      );
      expect(
        captionContrast(accent, Color.alphaBlend(veil, salmon)),
        greaterThanOrEqualTo(kCaptionMinContrast),
      );
    });
  });

  group('secondary text and OLED gradient', () {
    test('the veil also keeps onSurfaceVariant at the target contrast', () {
      const data = NavisColorStyleData(
        style: NavisColorStyle.neutral,
        dark: false,
      );
      const surface = Color(0xFFFFFBFE);
      const onSurface = Color(0xFF1C1B1F);
      const variant = Color(0xFF6B6872);
      var raised = 0;
      for (var v = 0x60; v <= 0xF0; v += 0x10) {
        final cover = Color.fromARGB(255, v, v - 8, v);
        final without = nowPlayingAdaptiveVeil(
          colorStyle: data,
          surface: surface,
          onSurface: onSurface,
          average: cover,
        );
        final withVariant = nowPlayingAdaptiveVeil(
          colorStyle: data,
          surface: surface,
          onSurface: onSurface,
          onSurfaceVariant: variant,
          average: cover,
        );
        expect(withVariant.a, greaterThanOrEqualTo(without.a));
        if (withVariant.a > without.a) raised++;
        if (withVariant.a < data.nowPlayingArtworkVeilRange.$2 - 0.001) {
          expect(
            captionContrast(variant, Color.alphaBlend(withVariant, cover)),
            greaterThanOrEqualTo(kNowPlayingArtworkTargetContrast),
          );
        }
      }
      expect(raised, greaterThan(0));
    });

    test('OLED art-tinted gradient tops out at tone 10', () {
      const data = NavisColorStyleData(
        style: NavisColorStyle.pastel,
        dark: true,
        oled: true,
      );
      for (final cover in <Color>[
        const Color(0xFFFFEB3B),
        const Color(0xFFE53935),
        Colors.white,
      ]) {
        final decoration = nowPlayingSurfaceDecoration(
          tintColor: cover,
          colorStyle: data,
          surfaceColor: Colors.black,
        );
        final top = (decoration.gradient! as LinearGradient).colors.first;
        expect(
          Hct.fromInt(top.withValues(alpha: 1).toARGB32()).tone,
          lessThanOrEqualTo(kNowPlayingOledMaxTintTone + 0.5),
        );
      }
    });
  });

  group('Now Playing panels over the Artwork layer', () {
    Future<Color> fill(
      WidgetTester tester, {
      required bool scoped,
      bool flat = false,
    }) async {
      late Color result;
      Widget probe() => Builder(
        builder: (context) {
          result = nowPlayingArtworkPanelFill(context, Colors.red);
          return const SizedBox.shrink();
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(
            const Color(0xFF3F7F6F),
            style: NavisColorStyle.pastel,
            flat: flat,
          ),
          home: scoped
              ? NowPlayingArtworkLayerScope(active: true, child: probe())
              : probe(),
        ),
      );
      return result;
    }

    testWidgets('are translucent only while the Artwork layer is active', (
      tester,
    ) async {
      final veiled = await fill(tester, scoped: true);
      expect(veiled, isNot(Colors.red));
      expect(veiled.a, closeTo(kNowPlayingArtworkPanelAlpha, 0.001));
      expect(await fill(tester, scoped: false), Colors.red);
    });

    testWidgets('stay opaque under Flat', (tester) async {
      expect(await fill(tester, scoped: true, flat: true), Colors.red);
    });
  });

  group('layer selection', () {
    test('only Artwork without Flat and with an image draws the layer', () {
      bool shows(
        NowPlayingBackground b, {
        bool flat = false,
        bool img = true,
      }) =>
          nowPlayingShowsArtworkLayer(background: b, flat: flat, hasImage: img);
      expect(shows(NowPlayingBackground.artwork), isTrue);
      expect(shows(NowPlayingBackground.artwork, flat: true), isFalse);
      expect(shows(NowPlayingBackground.artwork, img: false), isFalse);
      expect(shows(NowPlayingBackground.tinted), isFalse);
      expect(shows(NowPlayingBackground.plain), isFalse);
    });

    test(
      'plain is the solid surface, OLED + Flat artwork fallback is black',
      () {
        const data = NavisColorStyleData(
          style: NavisColorStyle.immersive,
          dark: true,
          flat: true,
          oled: true,
        );
        final plain = nowPlayingSurfaceDecoration(
          tintColor: null,
          colorStyle: data,
          surfaceColor: Colors.black,
        );
        expect(plain.color, Colors.black);
        final flatFallback = nowPlayingSurfaceDecoration(
          tintColor: const Color(0xFFD32F2F),
          colorStyle: data,
          surfaceColor: Colors.black,
        );
        expect(flatFallback.color, Colors.black);
        expect(flatFallback.gradient, isNull);
      },
    );
  });

  group('NowPlayingArtworkBackground', () {
    Widget host({
      required String? key,
      required ImageProvider? image,
      Duration fade = const Duration(milliseconds: 200),
      Color? average,
      bool useCoverAverage = false,
      void Function(String, {required bool available})? onAvailabilityChanged,
    }) => Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 200,
        height: 400,
        child: NowPlayingArtworkBackground(
          imageKey: key,
          image: image,
          coverAverage: average,
          useCoverAverage: useCoverAverage,
          onAvailabilityChanged: onAvailabilityChanged,
          colorStyle: const NavisColorStyleData(
            style: NavisColorStyle.neutral,
            dark: true,
          ),
          surfaceColor: const Color(0xFF101418),
          onSurfaceColor: Colors.white,
          fadeDuration: fade,
        ),
      ),
    );

    testWidgets(
      'disposes received image handles after averaging and when stale',
      (tester) async {
        final provider = _ControlledImage();
        await tester.pumpWidget(host(key: 'a', image: provider));
        final listener = provider.completer.listeners.single;
        final first = (await tester.runAsync(_countingInfo))!;
        listener.onImage(first, false);
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        expect(first.disposals, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        // A callback queued before disposal still owns its image handle.
        final stale = (await tester.runAsync(_countingInfo))!;
        listener.onImage(stale, false);
        expect(stale.disposals, 1);
      },
    );

    testWidgets(
      'cover art uses the shared field average and updates its veil',
      (tester) async {
        final provider = _ControlledImage();
        await tester.pumpWidget(
          host(key: 'cover', image: provider, useCoverAverage: true),
        );
        final info = (await tester.runAsync(_countingInfo))!;
        provider.completer.listeners.single.onImage(info, false);
        await tester.pump();
        const data = NavisColorStyleData.neutralDark;
        Color veil() =>
            tester.widget<ColoredBox>(find.byType(ColoredBox)).color;
        expect(veil(), data.nowPlayingArtworkVeil(const Color(0xFF101418)));
        expect(info.disposals, 1);
        final resolutions = provider.resolutions;
        await tester.pumpWidget(
          host(
            key: 'cover',
            image: provider,
            average: Colors.black,
            useCoverAverage: true,
          ),
        );
        expect(
          veil(),
          nowPlayingAdaptiveVeil(
            colorStyle: data,
            surface: const Color(0xFF101418),
            onSurface: Colors.white,
            average: Colors.black,
          ),
        );
        expect(provider.resolutions, resolutions);
        await tester.pumpWidget(
          host(
            key: 'cover',
            image: provider,
            average: Colors.white,
            useCoverAverage: true,
          ),
        );
        expect(
          veil(),
          nowPlayingAdaptiveVeil(
            colorStyle: data,
            surface: const Color(0xFF101418),
            onSurface: Colors.white,
            average: Colors.white,
          ),
        );
        expect(provider.resolutions, resolutions);
      },
    );

    testWidgets('remembers failed keys and reports the tinted fallback', (
      tester,
    ) async {
      final provider = _ControlledImage();
      final events = <(String, bool)>[];
      void report(String key, {required bool available}) =>
          events.add((key, available));
      await tester.pumpWidget(
        host(key: 'bad', image: provider, onAvailabilityChanged: report),
      );
      provider.completer.listeners.single.onError!(
        StateError('missing artwork'),
        StackTrace.current,
      );
      await tester.pump();
      expect(events, [('bad', false)]);
      expect(
        nowPlayingShowsArtworkLayer(
          background: NowPlayingBackground.artwork,
          flat: false,
          hasImage: events.last.$2,
        ),
        isFalse,
      );
      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(
          host(key: 'bad', image: provider, onAvailabilityChanged: report),
        );
      }
      expect(provider.resolutions, 1);
      expect(find.byType(Image), findsNothing);
      await tester.pumpWidget(
        host(
          key: 'new-revision',
          image: provider,
          onAvailabilityChanged: report,
        ),
      );
      expect(provider.resolutions, 2);
    });

    testWidgets('draws a blurred, veiled cover only after it decoded', (
      tester,
    ) async {
      final red = (await tester.runAsync(
        () => _solid(_covers['saturated red']!),
      ))!;
      await tester.pumpWidget(host(key: 'a', image: red));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(RepaintBoundary), findsWidgets);
    });

    testWidgets('keeps the previous cover until the next one is ready', (
      tester,
    ) async {
      final red = (await tester.runAsync(
        () => _solid(_covers['saturated red']!),
      ))!;
      await tester.pumpWidget(host(key: 'a', image: red));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);

      // A cover that never decodes: the old one stays, nothing flashes plain.
      final never = _NeverImage();
      await tester.pumpWidget(host(key: 'b', image: never));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(Image), findsOneWidget);
      expect(tester.widget<Image>(find.byType(Image)).image, same(red));

      // A null image (metadata gap) also keeps it.
      await tester.pumpWidget(host(key: null, image: null));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('crossfades to the next cover and honours reduced motion', (
      tester,
    ) async {
      final red = (await tester.runAsync(
        () => _solid(_covers['saturated red']!),
      ))!;
      final yellow = (await tester.runAsync(
        () => _solid(_covers['bright yellow']!),
      ))!;
      await tester.pumpWidget(host(key: 'a', image: red));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();

      await tester.pumpWidget(host(key: 'b', image: yellow));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Image), findsNWidgets(2));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(tester.widget<Image>(find.byType(Image)).image, same(yellow));

      await tester.pumpWidget(host(key: 'c', image: red, fade: Duration.zero));
      expect(
        tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration,
        Duration.zero,
      );
    });
  });
}

/// An image that never completes, standing in for a cover still downloading.
class _NeverImage extends ImageProvider<_NeverImage> {
  @override
  Future<_NeverImage> obtainKey(ImageConfiguration configuration) =>
      Future<_NeverImage>.value(this);

  @override
  ImageStreamCompleter loadImage(
    _NeverImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}

Future<_CountingInfo> _countingInfo() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = Colors.red);
  final picture = recorder.endRecording();
  final image = await picture.toImage(4, 4);
  picture.dispose();
  return _CountingInfo(image);
}

class _CountingInfo extends ImageInfo {
  new(ui.Image image) : super(image: image);
  final _DisposalCount _count = _DisposalCount();
  int get disposals => _count.value;
  @override
  void dispose() {
    _count.value++;
    super.dispose();
  }
}

class _ControlledCompleter extends ImageStreamCompleter {
  final listeners = <ImageStreamListener>[];
  @override
  void addListener(ImageStreamListener listener) => listeners.add(listener);
  @override
  void removeListener(ImageStreamListener listener) =>
      listeners.remove(listener);
}

class _ControlledImage extends ImageProvider<_ControlledImage> {
  final completer = _ControlledCompleter();
  int resolutions = 0;
  @override
  Future<_ControlledImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    _ControlledImage key,
    ImageErrorListener handleError,
  ) {
    resolutions++;
    stream.setCompleter(completer);
  }
}

class _DisposalCount {
  int value = 0;
}
