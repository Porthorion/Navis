import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
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
