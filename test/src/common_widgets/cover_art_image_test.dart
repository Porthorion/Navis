import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:file/local.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:octo_image/octo_image.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _FakeSubsonicApiClient extends SubsonicApiClient {
  new({super.baseUrl = 'https://example.com'})
    : super(
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );
}

Widget _buildWidget({
  required Widget child,
  List<Object> overrides = const <Object>[],
}) {
  return ProviderScope(
    overrides: overrides.cast(),
    child: MaterialApp(
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

Future<CacheManager> _createCacheManager(
  WidgetTester tester,
  CoverArtLoadCoordinator coordinator,
) async {
  // Repository I/O and persistence must drain outside fake time. Ensure open
  // completes before the widget uses the manager or teardown closes it.
  return (await tester.runAsync(() async {
    final manager = createCoverArtCacheManager(loadCoordinator: coordinator);
    await manager.getFileFromCache('initialization-probe');
    return manager;
  }))!;
}

/// Times out its first [timeouts] downloads, then serves [file].
class _TimingOutCacheManager extends Fake implements CacheManager {
  new(this.file, {required this.timeouts});

  final File file;
  final int timeouts;
  int downloads = 0;

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async => null;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    downloads++;
    if (downloads <= timeouts) {
      return Stream<FileResponse>.error(
        TimeoutException('cover timed out', const Duration(seconds: 20)),
      );
    }
    return Stream<FileResponse>.value(
      FileInfo(
        const LocalFileSystem().file(file.path),
        FileSource.Online,
        DateTime.now().add(const Duration(days: 1)),
        url,
      ),
    );
  }
}

final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cacheDirectory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(() {
    cacheDirectory = Directory.systemTemp.createTempSync(
      'navis-cover-art-test-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getTemporaryDirectory' ||
              call.method == 'getApplicationSupportDirectory') {
            return cacheDirectory.path;
          }
          throw UnsupportedError(
            'Unexpected path-provider call: ${call.method}',
          );
        });
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    cacheDirectory.deleteSync(recursive: true);
  });

  group('CoverArtImage', () {
    testWidgets('renders fallback icon when coverArtId is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildWidget(
          child: const CoverArtImage(
            coverArtId: null,
            width: 64,
            height: 64,
            placeholderIcon: Icons.album_outlined,
          ),
        ),
      );

      expect(find.byIcon(Icons.album_outlined), findsOneWidget);
    });

    testWidgets('renders fallback icon when api client is unavailable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildWidget(
          overrides: <Object>[subsonicApiProvider.overrideWith((_) => null)],
          child: const CoverArtImage(
            coverArtId: 'cover-1',
            width: 64,
            height: 64,
            placeholderIcon: Icons.music_note_outlined,
          ),
        ),
      );

      expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
    });

    testWidgets('a downloaded cover renders from disk without the network', (
      tester,
    ) async {
      final coordinator = CoverArtLoadCoordinator();
      final manager = await _createCacheManager(tester, coordinator);
      addTearDown(manager.dispose);
      final stored = File('${cacheDirectory.path}/stored-cover.png')
        ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);

      await tester.pumpWidget(
        _buildWidget(
          overrides: <Object>[
            subsonicApiProvider.overrideWithValue(_FakeSubsonicApiClient()),
            coverArtLoadCoordinatorProvider.overrideWithValue(coordinator),
            coverArtCacheManagerProvider.overrideWithValue(manager),
            permanentArtworkStoreProvider.overrideWithValue(
              _StoredArtwork(<String, File>{'cover-1': stored}),
            ),
          ],
          child: const CoverArtImage(
            coverArtId: 'cover-1',
            size: 80,
            width: 64,
            height: 64,
          ),
        ),
      );
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image;
      final file = switch (provider) {
        ResizeImage(imageProvider: FileImage(:final file)) => file,
        FileImage(:final file) => file,
        _ => null,
      };
      expect(file?.path, stored.path);
      // No network load was requested for the downloaded cover.
      expect(
        coordinator.interestCount(coverArtImageCacheKey('cover-1', 80)),
        1,
      );
      expect(find.byType(OctoImage), findsNothing);
    });

    testWidgets('a hero album cover renders a downloaded cover', (
      tester,
    ) async {
      final coordinator = CoverArtLoadCoordinator();
      final manager = await _createCacheManager(tester, coordinator);
      addTearDown(manager.dispose);
      final stored = File('${cacheDirectory.path}/stored-hero.png')
        ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);

      await tester.pumpWidget(
        _buildWidget(
          overrides: <Object>[
            subsonicApiProvider.overrideWithValue(_FakeSubsonicApiClient()),
            coverArtLoadCoordinatorProvider.overrideWithValue(coordinator),
            coverArtCacheManagerProvider.overrideWithValue(manager),
            permanentArtworkStoreProvider.overrideWithValue(
              _StoredArtwork(<String, File>{'cover-1': stored}),
            ),
          ],
          child: const HeroCoverArt(
            coverArtId: 'cover-1',
            heroTag: 'album-cover',
            size: kCoverArtStandardSize,
            width: 300,
            height: 300,
            loadPriority: CoverArtLoadPriority.critical,
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      expect(find.byType(OctoImage), findsNothing);
      final image = tester.widget<Image>(find.byType(Image));
      final file = switch (image.image) {
        ResizeImage(imageProvider: FileImage(:final file)) => file,
        FileImage(:final file) => file,
        _ => null,
      };
      expect(file?.path, stored.path);
    });

    testWidgets('a downloaded cover renders without a server connection', (
      tester,
    ) async {
      final stored = File('${cacheDirectory.path}/stored-offline.png')
        ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);
      await tester.pumpWidget(
        _buildWidget(
          overrides: <Object>[
            subsonicApiProvider.overrideWith((_) => null),
            permanentArtworkStoreProvider.overrideWithValue(
              _StoredArtwork(<String, File>{'cover-1': stored}),
            ),
          ],
          child: const CoverArtImage(
            coverArtId: 'cover-1',
            size: 600,
            width: 64,
            height: 64,
            placeholderIcon: Icons.music_note_outlined,
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.music_note_outlined), findsNothing);
      final image = tester.widget<Image>(find.byType(Image));
      final file = switch (image.image) {
        ResizeImage(imageProvider: FileImage(:final file)) => file,
        FileImage(:final file) => file,
        _ => null,
      };
      expect(file?.path, stored.path);
    });

    testWidgets('a refreshed cover that cannot load shows the downloaded one', (
      tester,
    ) async {
      final coordinator = CoverArtLoadCoordinator();
      final manager = await _createCacheManager(tester, coordinator);
      addTearDown(manager.dispose);
      final stored = File('${cacheDirectory.path}/stored-revision.png')
        ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);

      await tester.pumpWidget(
        _buildWidget(
          overrides: <Object>[
            subsonicApiProvider.overrideWithValue(_FakeSubsonicApiClient()),
            coverArtLoadCoordinatorProvider.overrideWithValue(coordinator),
            coverArtCacheManagerProvider.overrideWithValue(manager),
            permanentArtworkStoreProvider.overrideWithValue(
              _StoredArtwork(<String, File>{'cover-1': stored}),
            ),
          ],
          child: const CoverArtImage(
            coverArtId: 'cover-1',
            revision: 1,
            size: 600,
            width: 64,
            height: 64,
            placeholderIcon: Icons.music_note_outlined,
            loadPriority: CoverArtLoadPriority.critical,
          ),
        ),
      );
      // A refreshed revision tries the network first.
      expect(find.byType(OctoImage), findsOneWidget);
      // The test binding answers every HTTP request with 400.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }

      expect(find.byIcon(Icons.music_note_outlined), findsNothing);
      final files = tester
          .widgetList<Image>(find.byType(Image))
          .map(
            (image) => switch (image.image) {
              ResizeImage(imageProvider: FileImage(:final file)) => file.path,
              FileImage(:final file) => file.path,
              _ => null,
            },
          );
      expect(files, contains(stored.path));
    });

    group('a server cover that times out', () {
      Future<_TimingOutCacheManager> pumpTimingOut(
        WidgetTester tester, {
        required int timeouts,
      }) async {
        final file = File('${cacheDirectory.path}/timeout-retry-$timeouts.png')
          ..writeAsBytesSync(_onePixelPng);
        final manager = _TimingOutCacheManager(file, timeouts: timeouts);
        await tester.pumpWidget(
          _buildWidget(
            overrides: <Object>[
              subsonicApiProvider.overrideWithValue(_FakeSubsonicApiClient()),
              coverArtLoadCoordinatorProvider.overrideWithValue(
                CoverArtLoadCoordinator(),
              ),
              coverArtCacheManagerProvider.overrideWithValue(manager),
            ],
            child: CoverArtImage(
              // A distinct id per test: the global image cache keys on it.
              coverArtId: 'slow-cover-$timeouts',
              size: 300,
              width: 64,
              height: 64,
              placeholderIcon: Icons.music_note_outlined,
              loadPriority: CoverArtLoadPriority.critical,
            ),
          ),
        );
        return manager;
      }

      Future<void> settle(WidgetTester tester, Duration time) async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(time);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }

      testWidgets('is retried once and then shows the cover', (tester) async {
        final manager = await pumpTimingOut(tester, timeouts: 1);
        await settle(tester, Duration.zero);

        expect(manager.downloads, 1);
        expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);

        await settle(tester, const Duration(seconds: 3));
        expect(manager.downloads, 2);
        // The image decodes outside fake time.
        for (
          var i = 0;
          i < 20 && find.byType(RawImage).evaluate().isEmpty;
          i++
        ) {
          await settle(tester, const Duration(milliseconds: 50));
        }
        expect(find.byIcon(Icons.music_note_outlined), findsNothing);
        expect(find.byType(RawImage), findsOneWidget);
      });

      testWidgets('unmounting after a timeout cancels the pending retry', (
        tester,
      ) async {
        final manager = await pumpTimingOut(tester, timeouts: 98);
        await settle(tester, Duration.zero);
        expect(manager.downloads, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(
          tester,
          kCoverArtTimeoutRetryDelay + const Duration(seconds: 1),
        );
        expect(manager.downloads, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets('changing the cover clears its pending retry', (
        tester,
      ) async {
        final manager = await pumpTimingOut(tester, timeouts: 97);
        await settle(tester, Duration.zero);
        expect(manager.downloads, 1);
        // Keep the same state mounted while removing its cover identity.
        await tester.pumpWidget(
          _buildWidget(
            overrides: <Object>[
              subsonicApiProvider.overrideWithValue(_FakeSubsonicApiClient()),
              coverArtLoadCoordinatorProvider.overrideWithValue(
                CoverArtLoadCoordinator(),
              ),
              coverArtCacheManagerProvider.overrideWithValue(manager),
            ],
            child: const CoverArtImage(
              coverArtId: null,
              width: 64,
              height: 64,
              placeholderIcon: Icons.music_note_outlined,
            ),
          ),
        );
        await tester.pump();
        final placeholder = tester.widget<Icon>(
          find.byIcon(Icons.music_note_outlined),
        );
        await settle(
          tester,
          kCoverArtTimeoutRetryDelay + const Duration(seconds: 1),
        );
        // An obsolete timer would rebuild the replacement placeholder.
        expect(
          tester.widget<Icon>(find.byIcon(Icons.music_note_outlined)),
          same(placeholder),
        );
        expect(manager.downloads, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets('is never retried more than once', (tester) async {
        final manager = await pumpTimingOut(tester, timeouts: 99);
        await settle(tester, Duration.zero);
        await settle(tester, const Duration(seconds: 3));
        await settle(tester, const Duration(seconds: 30));

        expect(manager.downloads, 2);
        expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
      });
    });

    testWidgets('visibility changes register and unregister interest', (
      tester,
    ) async {
      final coordinator = CoverArtLoadCoordinator();
      final manager = await _createCacheManager(tester, coordinator);
      addTearDown(manager.dispose);

      await tester.pumpWidget(
        _buildWidget(
          overrides: <Object>[
            subsonicApiProvider.overrideWithValue(_FakeSubsonicApiClient()),
            coverArtLoadCoordinatorProvider.overrideWithValue(coordinator),
            coverArtCacheManagerProvider.overrideWithValue(manager),
          ],
          child: const CoverArtImage(
            coverArtId: 'cover-1',
            size: kCoverArtStandardSize,
            width: 64,
            height: 64,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        coordinator.interestCount(coverArtImageCacheKey('cover-1', 600)),
        1,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(
        coordinator.interestCount(coverArtImageCacheKey('cover-1', 600)),
        0,
      );
    });

    testWidgets('near-viewport covers register visible interest', (
      tester,
    ) async {
      final coordinator = CoverArtLoadCoordinator();
      final manager = await _createCacheManager(tester, coordinator);
      addTearDown(manager.dispose);

      await tester.pumpWidget(
        _buildWidget(
          overrides: <Object>[
            subsonicApiProvider.overrideWithValue(_FakeSubsonicApiClient()),
            coverArtLoadCoordinatorProvider.overrideWithValue(coordinator),
            coverArtCacheManagerProvider.overrideWithValue(manager),
          ],
          child: SizedBox(
            height: 100,
            width: 100,
            child: ListView(
              scrollCacheExtent: const ScrollCacheExtent.pixels(400),
              children: const <Widget>[
                SizedBox(height: 150),
                CoverArtImage(
                  coverArtId: 'cover-near',
                  size: kCoverArtStandardSize,
                  width: 64,
                  height: 64,
                ),
                SizedBox(height: 800),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        coordinator.interestCount(coverArtImageCacheKey('cover-near', 600)),
        1,
      );
    });

    testWidgets('far-offscreen covers do not register visible interest', (
      tester,
    ) async {
      final coordinator = CoverArtLoadCoordinator();
      final manager = await _createCacheManager(tester, coordinator);
      addTearDown(manager.dispose);

      await tester.pumpWidget(
        _buildWidget(
          overrides: <Object>[
            subsonicApiProvider.overrideWithValue(_FakeSubsonicApiClient()),
            coverArtLoadCoordinatorProvider.overrideWithValue(coordinator),
            coverArtCacheManagerProvider.overrideWithValue(manager),
          ],
          child: SizedBox(
            height: 100,
            width: 100,
            child: ListView(
              scrollCacheExtent: const ScrollCacheExtent.pixels(500),
              children: const <Widget>[
                SizedBox(height: 350),
                CoverArtImage(
                  coverArtId: 'cover-far',
                  size: kCoverArtStandardSize,
                  width: 64,
                  height: 64,
                ),
                SizedBox(height: 800),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        coordinator.interestCount(coverArtImageCacheKey('cover-far', 600)),
        0,
      );
    });

    testWidgets('critical images bypass viewport deferral', (tester) async {
      final coordinator = CoverArtLoadCoordinator();
      final manager = await _createCacheManager(tester, coordinator);
      addTearDown(manager.dispose);

      await tester.pumpWidget(
        _buildWidget(
          overrides: <Object>[
            subsonicApiProvider.overrideWithValue(_FakeSubsonicApiClient()),
            coverArtLoadCoordinatorProvider.overrideWithValue(coordinator),
            coverArtCacheManagerProvider.overrideWithValue(manager),
          ],
          child: const Offstage(
            child: CoverArtImage(
              coverArtId: 'cover-critical',
              size: kCoverArtStandardSize,
              width: 64,
              height: 64,
              loadPriority: CoverArtLoadPriority.critical,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        coordinator.interestCount(coverArtImageCacheKey('cover-critical', 600)),
        1,
      );
    });

    testWidgets(
      'remote indicator uses thumbnail top-left geometry and semantics',
      (tester) async {
        var taps = 0;
        await tester.pumpWidget(
          _buildWidget(
            child: GestureDetector(
              onTap: () => taps++,
              child: const CoverArtImage(
                coverArtId: null,
                width: 64,
                height: 64,
                isExternalSource: true,
              ),
            ),
          ),
        );

        final artRect = tester.getRect(find.byType(CoverArtImage));
        final badgeFinder = find.byKey(RemoteSourceIndicator.semanticsKey);
        final badgeRect = tester.getRect(badgeFinder);
        expect(badgeRect.size, const Size.square(18));
        expect(badgeRect.topLeft, artRect.topLeft + const Offset(4, 4));
        expect(
          tester.getSemantics(badgeFinder).label,
          'Remote source — not in your server library.',
        );
        expect(
          tester.getSemantics(badgeFinder).tooltip,
          'Remote source — not in your server library.',
        );

        await tester.tapAt(badgeRect.center);
        expect(taps, 1);
      },
    );

    testWidgets(
      'remote indicator uses large-art geometry and stays absent locally',
      (tester) async {
        await tester.pumpWidget(
          _buildWidget(
            child: const CoverArtImage(
              coverArtId: null,
              width: 160,
              height: 160,
              isExternalSource: true,
            ),
          ),
        );
        final artRect = tester.getRect(find.byType(CoverArtImage));
        final badgeRect = tester.getRect(
          find.byKey(RemoteSourceIndicator.semanticsKey),
        );
        expect(badgeRect.height, 24);
        expect(badgeRect.width, greaterThan(60));
        expect(find.text('Remote'), findsOneWidget);
        expect(badgeRect.topLeft, artRect.topLeft + const Offset(6, 6));

        await tester.pumpWidget(
          _buildWidget(
            child: const CoverArtImage(
              coverArtId: null,
              width: 160,
              height: 160,
            ),
          ),
        );
        expect(find.byKey(RemoteSourceIndicator.semanticsKey), findsNothing);
      },
    );

    testWidgets('artwork indicator policy can suppress a remote overlay', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildWidget(
          child: const CoverArtImage(
            coverArtId: null,
            width: 150,
            height: 150,
            isExternalSource: true,
            remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
          ),
        ),
      );

      expect(find.byKey(RemoteSourceIndicator.semanticsKey), findsNothing);
    });
  });
}

/// A download artwork store holding fixed covers.
class _StoredArtwork extends PermanentArtworkStore {
  new(this._files)
    : super(readApplicationSupportDirectory: Directory.systemTemp.createTemp);

  final Map<String, File> _files;

  @override
  File? loadedFileFor(String? coverArtId) => _files[coverArtId];

  @override
  Future<File?> fileFor(String? coverArtId) async => _files[coverArtId];
}
