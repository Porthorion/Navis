import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';

Future<ImageProvider<Object>> _image(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const colors = [
    Color(0xffdc3c28),
    Color(0xff2054bc),
    Color(0xff46a85c),
    Color(0xffdeb634),
    Color(0xff9828ac),
    Color(0x8048b8c8),
  ];
  for (var i = 0; i < colors.length; i++) {
    canvas.drawRect(
      Rect.fromLTRB(
        width * i / colors.length,
        0,
        width * (i + 1) / colors.length,
        height.toDouble(),
      ),
      Paint()..color = colors[i],
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return MemoryImage(bytes.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

void main() {
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  for (final (width, height) in [(32, 24), (224, 128)]) {
    for (final brightness in Brightness.values) {
      for (final variant in [
        DynamicSchemeVariant.tonalSpot,
        DynamicSchemeVariant.fidelity,
      ]) {
        testWidgets(
          'matches Material for ${width}x$height ${brightness.name}/${variant.name}',
          (tester) async {
            await tester.runAsync(() async {
              final provider = await _image(width, height);
              final expected = await ColorScheme.fromImageProvider(
                provider: provider,
                brightness: brightness,
                dynamicSchemeVariant: variant,
              );
              final actual = await artworkColorScheme(
                provider: provider,
                brightness: brightness,
                dynamicSchemeVariant: variant,
              );
              // ColorScheme equality compares every colour role and brightness.
              expect(actual, expected);
            });
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final (width, height) in [(1, 224), (224, 1)]) {
    testWidgets('rejects ${width}x$height before an edge rounds to zero', (
      tester,
    ) async {
      await tester.runAsync(() async {
        expect(
          await artworkColorScheme(
            provider: await _image(width, height),
            brightness: Brightness.dark,
          ),
          isNull,
        );
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('times out loading and removes its image listener', (
    tester,
  ) async {
    final provider = _PendingImage();
    final future = artworkColorScheme(
      provider: provider,
      brightness: Brightness.light,
    );
    await tester.pump();
    expect(provider.completer.hasListeners, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(await future, isNull);
    expect(provider.completer.hasListeners, isFalse);
    expect(tester.takeException(), isNull);
  });
}

class _PendingImage extends ImageProvider<_PendingImage> {
  final completer = OneFrameImageStreamCompleter(Completer<ImageInfo>().future);

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
