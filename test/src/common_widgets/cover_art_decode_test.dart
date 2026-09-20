import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _CachedManager extends Mock implements CacheManager {}

void main() {
  for (final dimensions in [(2400, 2400), (1200, 600), (60, 120)]) {
    testWidgets(
      'bounds both decode paths for ${dimensions.$1}x${dimensions.$2}',
      (
        tester,
      ) async {
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        final dir = Directory.systemTemp.createTempSync('navis-art-decode-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = const LocalFileSystem().file('${dir.path}/oversized.png');
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
          final original = await picture.toImage(dimensions.$1, dimensions.$2);
          final png = await original.toByteData(format: ui.ImageByteFormat.png);
          file.writeAsBytesSync(png!.buffer.asUint8List());
          original.dispose();
          picture.dispose();
        });
        final info = FileInfo(
          file,
          FileSource.Cache,
          DateTime.now().add(const Duration(days: 1)),
          'https://example.test/oversized.png',
        );
        final manager = _CachedManager();
        when(() => manager.getFileFromCache(any()))
            .thenAnswer((_) async => info);
        when(
          () => manager.getFileStream(
            any(),
            key: any(named: 'key'),
            headers: any(named: 'headers'),
            withProgress: any(named: 'withProgress'),
          ),
        ).thenAnswer((_) => Stream<FileResponse>.value(info));
        final api = SubsonicApiClient(
          baseUrl: 'https://example.test',
          authConfig: const SubsonicAuthConfig(
            username: 'fixture',
            password: 'fixture',
            apiVersion: '1.16.1',
          ),
          enableLogging: false,
        );

        for (final hero in [false, true]) {
          for (final admitted in [false, true]) {
            final key =
                '${hero ? 'hero' : 'thumbnail'}-${admitted ? 'admitted' : 'cached'}';
            var readyCount = 0;
            Widget buildArtwork({double extent = 100}) => ProviderScope(
              overrides: [
                subsonicApiProvider.overrideWithValue(api),
                coverArtCacheManagerProvider.overrideWithValue(manager),
                coverArtLoadCoordinatorProvider.overrideWithValue(
                  CoverArtLoadCoordinator(),
                ),
              ],
              child: MaterialApp(
                home: Offstage(
                  child: CoverArtImage(
                    key: ValueKey(key),
                    coverArtId: 'oversized-$key',
                    onImageReady: () => readyCount++,
                    size: 600,
                    width: extent,
                    height: extent,
                    useRequestedMemCacheSize: hero,
                    loadPriority: admitted
                        ? CoverArtLoadPriority.critical
                        : CoverArtLoadPriority.visible,
                  ),
                ),
              ),
            );
            await tester.pumpWidget(buildArtwork());
            ui.Image? decoded;
            for (var i = 0; i < 50; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump();
              final raw = tester.widgetList<RawImage>(
                find.byType(RawImage, skipOffstage: false),
              );
              if (raw.isNotEmpty) decoded = raw.last.image;
              if (decoded != null) break;
            }
            expect(decoded, isNotNull, reason: key);
            final bound = hero ? 600 : 200;
            final longest = dimensions.$1 > dimensions.$2
                ? dimensions.$1
                : dimensions.$2;
            final scale = longest > bound ? bound / longest : 1.0;
            expect(
              decoded!.width,
              (dimensions.$1 * scale).round(),
              reason: key,
            );
            expect(
              decoded.height,
              (dimensions.$2 * scale).round(),
              reason: key,
            );
            if (hero) {
              final sourceImage = decoded.clone();
              try {
                await tester.pumpWidget(buildArtwork(extent: 360));
                await tester.pump();
                final destinationImage = tester
                    .widgetList<RawImage>(
                      find.byType(RawImage, skipOffstage: false),
                    )
                    .last
                    .image;
                expect(destinationImage, isNotNull, reason: key);
                expect(
                  destinationImage!.isCloneOf(sourceImage),
                  isTrue,
                  reason: 'Hero layout changes must reuse the decoded image',
                );
              } finally {
                sourceImage.dispose();
              }
            }
            // The callback must follow decoding and must not repeat on a new frame.
            if (admitted) {
              await tester.pump(const Duration(milliseconds: 200));
              expect(readyCount, 1, reason: key);
              await tester.pump();
              expect(readyCount, 1, reason: key);
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
          }
        }
      },
    );
  }
}
