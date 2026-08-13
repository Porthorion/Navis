import 'dart:async';

import 'package:flutter/material.dart';
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
        overrides: [
          subsonicApiProvider.overrideWith((_) => null),
        ],
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
  });

  testWidgets('fades source card chrome back in after a hero return', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subsonicApiProvider.overrideWith((_) => null),
        ],
        child: const MaterialApp(home: _HeroSourcePage()),
      ),
    );

    await tester.tap(find.byKey(const Key('open-album')));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final chromeOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('Source album metadata', skipOffstage: false),
        matching: find.byType(Opacity),
      ),
    );
    expect(chromeOpacity.opacity, greaterThan(0));
    expect(chromeOpacity.opacity, lessThan(1));
  });
}

class _HeroSourcePage extends StatelessWidget {
  const _HeroSourcePage();

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
                unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const _HeroDestinationPage(),
                    ),
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
                enabled: true,
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
  const _HeroDestinationPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
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
