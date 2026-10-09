import 'dart:io';
import 'dart:ui' as ui;

import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/external_artwork_image.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:path/path.dart' as p;

class _CachedManager extends Mock implements CacheManager;

void main() {
  for (final dimensions in [(128, 4096), (4096, 128)]) {
    testWidgets(
      'radio prewarm and display share a bounded decode for ${dimensions.$1}x${dimensions.$2}',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'external-art-decode-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final file = const LocalFileSystem().file(
          p.join(directory.path, 'cover.png'),
        );
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
            Rect.fromLTWH(
              0,
              0,
              dimensions.$1.toDouble(),
              dimensions.$2.toDouble(),
            ),
            Paint()..color = Colors.blue,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(dimensions.$1, dimensions.$2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await file.writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        });
        final url =
            'https://images.example.test/${dimensions.$1}x${dimensions.$2}.png';
        final info = FileInfo(file, FileSource.Cache, DateTime(2100), url);
        final manager = _CachedManager();
        when(
          () => manager.getFileStream(
            any(),
            key: any(named: 'key'),
            headers: any(named: 'headers'),
            withProgress: any(named: 'withProgress'),
          ),
        ).thenAnswer((_) => Stream<FileResponse>.value(info));
        final container = ProviderContainer(
          overrides: [
            coverArtCacheManagerProvider.overrideWithValue(manager),
            integrationPolicyProvider.overrideWithValue(
              const IntegrationPolicy(),
            ),
            serverHostProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(() {
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        });
        late BuildContext warmContext;
        late WidgetRef warmRef;
        var display = false;
        Widget harness() => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                warmContext = context;
                warmRef = ref;
                return display
                    ? ExternalArtworkImage(
                        url: url,
                        feature: IntegrationFeature.radioNowPlaying,
                        width: 200,
                        height: 200,
                        fallbackBuilder: (_) =>
                            const SizedBox(key: ValueKey('fallback')),
                      )
                    : const SizedBox();
              },
            ),
          ),
        );
        await tester.pumpWidget(harness());
        await tester.runAsync(
          () => prewarmNowPlayingVisuals(
            context: warmContext,
            ref: warmRef,
            brightness: Brightness.light,
            artUrl: url,
          ),
        );
        // Keep a reference to the decoded prewarm frame and compare the actual
        // display frame, not just two independently constructed provider keys.
        final provider = externalArtworkImageProvider(
          url: url,
          cacheManager: manager,
          feature: IntegrationFeature.radioNowPlaying,
        );
        final stream = provider.resolve(
          createLocalImageConfiguration(warmContext),
        );
        ui.Image? warmed;
        var synchronous = false;
        final listener = ImageStreamListener((info, sync) {
          warmed = info.image.clone();
          synchronous = sync;
        });
        stream.addListener(listener);
        expect(
          synchronous,
          isTrue,
          reason: 'prewarming populated this decode key',
        );
        expect(warmed, isNotNull);
        stream.removeListener(listener);
        addTearDown(() => warmed?.dispose());

        display = true;
        await tester.pumpWidget(harness());
        final widget = tester.widget<Image>(find.byType(Image));
        expect(
          await widget.image.obtainKey(ImageConfiguration.empty),
          await provider.obtainKey(ImageConfiguration.empty),
        );
        final displayed = tester.widget<RawImage>(find.byType(RawImage)).image;
        expect(displayed, isNotNull);
        expect(displayed!.isCloneOf(warmed!), isTrue);
        expect(displayed.width, dimensions.$1 ~/ 4);
        expect(displayed.height, dimensions.$2 ~/ 4);
        expect(displayed.width, lessThanOrEqualTo(kMaxArtworkDecodeEdge));
        expect(displayed.height, lessThanOrEqualTo(kMaxArtworkDecodeEdge));
        expect(
          find.byKey(const ValueKey('fallback')),
          findsNothing,
          reason: 'a prewarmed frame displays immediately without a fade',
        );
      },
    );
  }
}
