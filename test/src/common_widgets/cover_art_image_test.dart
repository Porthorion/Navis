import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _FakeSubsonicApiClient extends SubsonicApiClient {
  _FakeSubsonicApiClient()
    : super(
        baseUrl: 'https://example.com',
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
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

Future<void> _disposeCacheManager(CacheManager manager) async {
  await Future<void>.delayed(const Duration(milliseconds: 200));
  try {
    await manager.dispose();
  } on Object {
    // flutter_cache_manager can throw when disposed before its JSON repository
    // has finished lazy initialization; these tests only need provider cleanup.
  }
}

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
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
          overrides: <Object>[
            subsonicApiProvider.overrideWith((_) => null),
          ],
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
      final manager = createCoverArtCacheManager(
        loadCoordinator: coordinator,
      );
      addTearDown(() => _disposeCacheManager(manager));

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

    testWidgets('critical images bypass viewport deferral', (tester) async {
      final coordinator = CoverArtLoadCoordinator();
      final manager = createCoverArtCacheManager(
        loadCoordinator: coordinator,
      );
      addTearDown(() => _disposeCacheManager(manager));

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
        coordinator.interestCount(
          coverArtImageCacheKey('cover-critical', 600),
        ),
        1,
      );
    });
  });
}
