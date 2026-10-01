import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/providers/app_providers.dart';

void main() {
  test('uses the entity ID to keep equal cover art hero tags distinct', () {
    expect(
      buildCoverArtHeroTag(
        coverArtId: 'shared-art',
        context: 'album',
        entityId: 'album-a',
      ),
      isNot(
        buildCoverArtHeroTag(
          coverArtId: 'shared-art',
          context: 'album',
          entityId: 'album-b',
        ),
      ),
    );
  });

  testWidgets('keeps the source cover-art cache key during a hero flight', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [subsonicApiProvider.overrideWith((_) => null)],
        child: const MaterialApp(home: _HeroSourcePage()),
      ),
    );

    await tester.tap(find.byKey(const Key('open-album')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final flightImage = tester
        .widgetList<CoverArtImage>(find.byType(CoverArtImage))
        .singleWhere((image) => image.lockedSize != null);
    expect(flightImage.size, kCoverArtStandardSize);
    expect(flightImage.lockedSize, kCoverArtStandardSize);
    expect(flightImage.fadeInDuration, Duration.zero);
    expect(flightImage.gaplessPlayback, isTrue);
    expect(flightImage.useRequestedMemCacheSize, isTrue);
  });

  testWidgets('uses a stable decoded image contract on both hero endpoints', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [subsonicApiProvider.overrideWith((_) => null)],
        child: const MaterialApp(home: _HeroSourcePage()),
      ),
    );

    final sourceImage = tester.widget<CoverArtImage>(
      find.byType(CoverArtImage),
    );
    expect(sourceImage.fadeInDuration, Duration.zero);
    expect(sourceImage.useRequestedMemCacheSize, isTrue);

    await tester.tap(find.byKey(const Key('open-album')));
    await tester.pumpAndSettle();
    final destinationImage = tester
        .widgetList<CoverArtImage>(find.byType(CoverArtImage))
        .last;
    expect(destinationImage.fadeInDuration, Duration.zero);
    expect(destinationImage.useRequestedMemCacheSize, isTrue);
  });

  testWidgets('fades source card chrome only after the hero return completes', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [subsonicApiProvider.overrideWith((_) => null)],
        child: const MaterialApp(home: _HeroSourcePage()),
      ),
    );

    await tester.tap(find.byKey(const Key('open-album')));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final duringHeroOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('Source album metadata', skipOffstage: false),
        matching: find.byType(Opacity),
      ),
    );
    expect(duringHeroOpacity.opacity, 0);

    final sourceRoute = ModalRoute.of(
      tester.element(find.text('Source album metadata', skipOffstage: false)),
    )!;
    for (
      var frame = 0;
      frame < 40 &&
          sourceRoute.secondaryAnimation!.status != AnimationStatus.dismissed;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(sourceRoute.secondaryAnimation!.status, AnimationStatus.dismissed);

    final settledHeroOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('Source album metadata', skipOffstage: false),
        matching: find.byType(Opacity),
      ),
    );
    expect(settledHeroOpacity.opacity, 0);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final settledReturnOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('Source album metadata', skipOffstage: false),
        matching: find.byType(Opacity),
      ),
    );
    expect(settledReturnOpacity.opacity, greaterThan(0));
    expect(settledReturnOpacity.opacity, lessThan(1));
  });
}

class _HeroSourcePage extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            GestureDetector(
              key: const Key('open-album'),
              onTap: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const _HeroDestinationPage(),
                  ),
                );
              },
              child: HeroCoverArt(
                coverArtId: null,
                heroTag: 'album-hero',
                size: kCoverArtStandardSize,
                width: 96,
                height: 96,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            const Align(
              alignment: Alignment.bottomCenter,
              child: HeroRouteChrome(
                heroTag: 'album-hero',
                child: Text('Source album metadata'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroDestinationPage extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: HeroCoverArt(
          coverArtId: null,
          heroTag: 'album-hero',
          size: 300,
          width: 300,
          height: 300,
        ),
      ),
    );
  }
}
