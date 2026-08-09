import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cache_badge.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  testWidgets('variants share semantics and stay pointer transparent', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: GestureDetector(
              onTap: () => taps++,
              child: const Wrap(
                children: <Widget>[
                  RemoteSourceIndicator(
                    variant: RemoteSourceIndicatorVariant.artwork,
                  ),
                  RemoteSourceIndicator(
                    variant: RemoteSourceIndicatorVariant.compactArtwork,
                  ),
                  RemoteSourceIndicator(
                    variant: RemoteSourceIndicatorVariant.inline,
                  ),
                  RemoteSourceIndicator(
                    variant: RemoteSourceIndicatorVariant.chip,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final indicators = find.byKey(RemoteSourceIndicator.semanticsKey);
    expect(indicators, findsNWidgets(4));
    for (final element in indicators.evaluate()) {
      expect(
        tester.getSemantics(find.byWidget(element.widget)).label,
        'Remote source — not in your server library.',
      );
    }
    await tester.tapAt(tester.getCenter(indicators.first));
    expect(taps, 1);
  });

  testWidgets('inline source and download states fit a narrow metadata row', (
    tester,
  ) async {
    for (final width in <double>[220, 800]) {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Artist and album metadata that truncates',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 2),
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        RemoteSourceIndicator(
                          variant: RemoteSourceIndicatorVariant.inline,
                        ),
                        CacheBadge(),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Remote'), findsOneWidget);
      expect(find.text('Downloaded'), findsOneWidget);
    }
  });

  testWidgets('metadata line truncates before Remote without changing height', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: SizedBox(
            width: 220,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  key: ValueKey<String>('local-metadata-line'),
                  child: RemoteSourceMetadataLine(
                    metadata: Text(
                      'A very long artist and album metadata value',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    isRemote: false,
                  ),
                ),
                SizedBox(
                  key: ValueKey<String>('remote-metadata-line'),
                  child: RemoteSourceMetadataLine(
                    metadata: Text(
                      'A very long artist and album metadata value',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    isRemote: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Remote'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('local-metadata-line'))).height,
      tester.getSize(find.byKey(const ValueKey('remote-metadata-line'))).height,
    );
  });

  testWidgets('artwork indicator stays outside Hero transitions', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: HeroCoverArt(
              coverArtId: null,
              heroTag: 'remote-indicator-test',
              width: 150,
              height: 150,
              isExternalSource: true,
            ),
          ),
        ),
      ),
    );

    final indicator = find.byKey(RemoteSourceIndicator.semanticsKey);
    expect(indicator, findsOneWidget);
    expect(
      find.ancestor(of: indicator, matching: find.byType(Hero)),
      findsNothing,
    );
  });

  testWidgets('renders responsive variants in light dark and OLED themes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(840, 320);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Row(
              key: const ValueKey<String>('remote-indicator-golden'),
              children: <Widget>[
                _IndicatorThemeSample(
                  label: 'Light',
                  theme: buildLightTheme(Colors.indigo),
                ),
                _IndicatorThemeSample(
                  label: 'Dark',
                  theme: buildDarkTheme(Colors.indigo),
                ),
                _IndicatorThemeSample(
                  label: 'OLED',
                  theme: buildOledTheme(Colors.indigo),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const ValueKey<String>('remote-indicator-golden')),
      matchesGoldenFile('goldens/remote_source_indicator_variants.png'),
    );
  });
}

class _IndicatorThemeSample extends StatelessWidget {
  const _IndicatorThemeSample({required this.label, required this.theme});

  final String label;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Theme(
        data: theme,
        child: Builder(
          builder: (context) => ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(label, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 12),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      SizedBox.square(
                        dimension: 48,
                        child: CoverArtImage(
                          coverArtId: null,
                          width: 48,
                          height: 48,
                          isExternalSource: true,
                        ),
                      ),
                      SizedBox(width: 12),
                      SizedBox.square(
                        dimension: 150,
                        child: CoverArtImage(
                          coverArtId: null,
                          width: 150,
                          height: 150,
                          isExternalSource: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      RemoteSourceIndicator(
                        variant: RemoteSourceIndicatorVariant.inline,
                      ),
                      RemoteSourceIndicator(
                        variant: RemoteSourceIndicatorVariant.chip,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
