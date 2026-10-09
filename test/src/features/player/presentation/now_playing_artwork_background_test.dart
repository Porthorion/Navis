import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
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
  return MemoryImage(Uint8List.view(bytes.buffer));
}

void main() {
  group('Artwork veil keeps on-surface text readable', () {
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
        _covers.forEach((name, cover) {
          test('${style.name} $mode over $name', () {
            final veiled = Color.alphaBlend(
              data.nowPlayingArtworkVeil(surface),
              cover,
            );
            expect(
              captionContrast(onSurface, veiled),
              greaterThanOrEqualTo(kCaptionMinContrast),
            );
          });
        });
      }
    }

    test('OLED veil stays heavier than the dark veil', () {
      const dark = NavisColorStyleData(
        style: NavisColorStyle.neutral,
        dark: true,
      );
      const oled = NavisColorStyleData(
        style: NavisColorStyle.neutral,
        dark: true,
        oled: true,
      );
      expect(
        oled.nowPlayingArtworkVeil(Colors.black).a,
        greaterThan(dark.nowPlayingArtworkVeil(Colors.black).a),
      );
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
    }) => Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 200,
        height: 400,
        child: NowPlayingArtworkBackground(
          imageKey: key,
          image: image,
          veil: const Color(0x99000000),
          surfaceColor: const Color(0xFF101418),
          fadeDuration: fade,
        ),
      ),
    );

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
