import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/external_artwork_image.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Fails every load, which is enough to show which path the widget took.
class _FailingCacheManager extends Fake implements CacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => Stream<FileResponse>.error(StateError('no network in tests'));
}

class _UntouchableCacheManager extends Fake implements CacheManager;

const _fallbackKey = ValueKey<String>('fallback');

Widget _harness({
  required IntegrationPolicy policy,
  required String url,
  required CacheManager manager,
  IntegrationFeature? feature,
  String? serverHost = 'music.example.org',
}) {
  return ProviderScope(
    overrides: [
      integrationPolicyProvider.overrideWithValue(policy),
      serverHostProvider.overrideWithValue(serverHost),
      coverArtCacheManagerProvider.overrideWithValue(manager),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ExternalArtworkImage(
          url: url,
          width: 64,
          height: 64,
          feature: feature,
          fallbackBuilder: (_) => const SizedBox.square(
            key: _fallbackKey,
            dimension: 64,
            child: Icon(Icons.person),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('loads an allowed URL through the cover art cache manager', (
    tester,
  ) async {
    final manager = _FailingCacheManager();
    await tester.pumpWidget(
      _harness(
        policy: const IntegrationPolicy(),
        url: 'https://images.example.com/a.jpg',
        manager: manager,
      ),
    );

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.cacheManager, same(manager));
    expect(image.imageUrl, 'https://images.example.com/a.jpg');
  });

  testWidgets('a radio image names its feature on the request', (tester) async {
    await tester.pumpWidget(
      _harness(
        policy: const IntegrationPolicy(),
        url: 'https://images.example.com/a.jpg',
        manager: _FailingCacheManager(),
        feature: IntegrationFeature.radioNowPlaying,
      ),
    );
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.httpHeaders, {coverArtFeatureHeader: 'radio.nowPlaying'});
  });

  testWidgets('shows the fallback when loading fails', (tester) async {
    await tester.pumpWidget(
      _harness(
        policy: const IntegrationPolicy(),
        url: 'https://images.example.com/a.jpg',
        manager: _FailingCacheManager(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(_fallbackKey), findsOneWidget);
  });

  for (final entry in <String, IntegrationPolicy>{
    'the master switch is off': const IntegrationPolicy(masterEnabled: false),
    'server-linked artwork is off': const IntegrationPolicy(
      disabledKeys: {'artwork.serverLinked'},
    ),
    'settings are still loading': const IntegrationPolicy.denyAll(),
  }.entries) {
    testWidgets('shows the fallback and never touches the cache when '
        '${entry.key}', (tester) async {
      await tester.pumpWidget(
        _harness(
          policy: entry.value,
          url: 'https://images.example.com/a.jpg',
          manager: _UntouchableCacheManager(),
        ),
      );

      expect(find.byKey(_fallbackKey), findsOneWidget);
      expect(find.byType(CachedNetworkImage), findsNothing);
    });
  }

  testWidgets('server artwork loads even when every integration is off', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        policy: const IntegrationPolicy.denyAll(),
        url: 'https://music.example.org/rest/getCoverArt.view?id=1',
        manager: _FailingCacheManager(),
      ),
    );

    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.byKey(_fallbackKey), findsNothing);
  });

  testWidgets('Deezer artwork follows the Deezer artist images switch', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        policy: const IntegrationPolicy(disabledKeys: {'deezer.artistImages'}),
        url: 'https://e-cdns-images.dzcdn.net/images/artist/a/500x500.jpg',
        manager: _UntouchableCacheManager(),
      ),
    );
    expect(find.byKey(_fallbackKey), findsOneWidget);
  });

  testWidgets('radio art follows the radio switch, not artwork', (
    tester,
  ) async {
    const url = 'https://radio.example.com/art.jpg';
    await tester.pumpWidget(
      _harness(
        policy: const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'}),
        url: url,
        feature: IntegrationFeature.radioNowPlaying,
        manager: _UntouchableCacheManager(),
      ),
    );
    expect(find.byKey(_fallbackKey), findsOneWidget);

    await tester.pumpWidget(
      _harness(
        policy: const IntegrationPolicy(disabledKeys: {'artwork.serverLinked'}),
        url: url,
        feature: IntegrationFeature.radioNowPlaying,
        manager: _FailingCacheManager(),
      ),
    );
    expect(find.byType(CachedNetworkImage), findsOneWidget);
  });

  testWidgets('a URL that cannot be parsed shows the fallback', (tester) async {
    await tester.pumpWidget(
      _harness(
        policy: const IntegrationPolicy(),
        url: 'not a url',
        manager: _UntouchableCacheManager(),
      ),
    );
    expect(find.byKey(_fallbackKey), findsOneWidget);
  });

  testWidgets('turning the integration off swaps the image for the fallback', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        serverHostProvider.overrideWithValue(null),
        coverArtCacheManagerProvider.overrideWithValue(_FailingCacheManager()),
        integrationPolicyProvider.overrideWith(
          (ref) => ref.watch(_policyState),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ExternalArtworkImage(
            url: 'https://images.example.com/a.jpg',
            fallbackBuilder: (_) => const SizedBox(key: _fallbackKey),
          ),
        ),
      ),
    );
    expect(find.byType(CachedNetworkImage), findsOneWidget);

    container
        .read(_policyState.notifier)
        .replace(const IntegrationPolicy(masterEnabled: false));
    await tester.pump();

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byKey(_fallbackKey), findsOneWidget);
  });
}

class _PolicyController extends Notifier<IntegrationPolicy> {
  @override
  IntegrationPolicy build() => const IntegrationPolicy();

  // A named method reads better than a setter at the call site.
  // ignore: use_setters_to_change_properties
  void replace(IntegrationPolicy policy) => state = policy;
}

final _policyState = NotifierProvider<_PolicyController, IntegrationPolicy>(
  _PolicyController.new,
);
