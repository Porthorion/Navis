import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/content_shelf.dart';
import 'package:navis/src/common_widgets/responsive_content_grid.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_theme.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/test_theme.dart';

void main() {
  for (final width in <double>[390, 1040, 2000, 3440]) {
    testWidgets('collection at $width adds bounded columns and stays lazy', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, Size(width, 800));
      final built = <int>{};
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gridArtworkSizeProvider.overrideWithValue(GridArtworkSize.auto),
          ],
          child: MaterialApp(
            theme: testTheme(),
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  ResponsiveContentSliverGrid(
                    itemCount: 240,
                    itemBuilder: (_, index) {
                      built.add(index);
                      return ColoredBox(
                        key: ValueKey(index),
                        color: Colors.blue,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = tester.getRect(find.byKey(const ValueKey(0)));
      expect(first.width, lessThanOrEqualTo(220));
      expect(first.height, first.width);
      final second = tester.getRect(find.byKey(const ValueKey(1)));
      expect(second.top, first.top);
      expect(second.left, greaterThan(first.right));
      expect(built.length, lessThan(240));
      expect(tester.takeException(), isNull);
    });
  }

  group('album cells', () {
    Future<(Size, double)> render(
      WidgetTester tester, {
      required bool flat,
      double textScale = 1,
    }) async {
      setAdaptiveTestViewport(tester, const Size(1040, 800));
      late double extra;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gridArtworkSizeProvider.overrideWithValue(GridArtworkSize.auto),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(Colors.teal, flat: flat),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(1040, 800),
                textScaler: TextScaler.linear(textScale),
              ),
              child: Scaffold(
                body: CustomScrollView(
                  slivers: [
                    ResponsiveContentSliverGrid(
                      itemCount: 12,
                      itemBuilder: (context, index) {
                        extra = albumCardExtraHeight(context, titleMaxLines: 2);
                        return ColoredBox(
                          key: ValueKey(index),
                          color: Colors.blue,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return (tester.getSize(find.byKey(const ValueKey(0))), extra);
    }

    testWidgets('stay square unless Flat text over artwork is on', (
      tester,
    ) async {
      final (size, extra) = await render(tester, flat: false);
      expect(extra, 0);
      expect(size.height, size.width);
    });

    testWidgets('grow by the caption height under Flat text over artwork', (
      tester,
    ) async {
      final (size, extra) = await render(tester, flat: true);
      expect(extra, greaterThan(0));
      expect(size.height, closeTo(size.width + extra, 0.01));
    });

    testWidgets('caption space follows the text scale', (tester) async {
      final (normal, normalExtra) = await render(tester, flat: true);
      final (scaled, scaledExtra) = await render(
        tester,
        flat: true,
        textScale: 2,
      );
      expect(scaledExtra, greaterThan(normalExtra));
      expect(scaled.height - scaled.width, closeTo(scaledExtra, 0.01));
      expect(normal.width, scaled.width);
    });
  });

  testWidgets(
    'artist label space grows with text scale instead of shrinking art',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(1040, 800));
      Future<double> render(TextScaler scaler) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              gridArtworkSizeProvider.overrideWithValue(GridArtworkSize.auto),
            ],
            child: MaterialApp(
              theme: testTheme(),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(1040, 800),
                  textScaler: scaler,
                ),
                child: Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      ResponsiveContentSliverGrid(
                        artists: true,
                        itemCount: 12,
                        itemBuilder: (_, index) => ColoredBox(
                          key: ValueKey(index),
                          color: Colors.blue,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        return tester.getSize(find.byKey(const ValueKey(0))).height;
      }

      final ordinary = await render(TextScaler.noScaling);
      final scaled = await render(const TextScaler.linear(2));
      expect(scaled, greaterThan(ordinary));
    },
  );

  testWidgets('shelf arrows respond to resize and preserve manual position', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdaptiveContextScope(
          adaptiveContext: resolveAdaptiveContext(
            desktopRuntime: true,
            viewportSize: const Size(1200, 800),
            safePadding: EdgeInsets.zero,
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: ContentShelf(
                itemCount: 12,
                extent: 148,
                height: 148,
                gap: 12,
                itemBuilder: (_, index) =>
                    ColoredBox(color: Colors.blue, child: Text('$index')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Next items'), findsOneWidget);
    await tester.tap(find.byTooltip('Next items'));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    final offset = scrollable.position.pixels;
    expect(offset, greaterThan(0));
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, offset);
    expect(find.byTooltip('Previous items'), findsOneWidget);
    tester.view.physicalSize = const Size(2200, 800);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Next items'), findsNothing);
    expect(find.byTooltip('Previous items'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
