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
                        extra = albumCardExtraHeight(context);
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

  group('scroll anchor', () {
    Future<ScrollController> pumpGrids(
      WidgetTester tester, {
      required Size size,
      required List<int> sections,
    }) async {
      setAdaptiveTestViewport(tester, size);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final anchor = GridScrollAnchor();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gridArtworkSizeProvider.overrideWithValue(GridArtworkSize.auto),
          ],
          child: MaterialApp(
            theme: testTheme(),
            home: Scaffold(
              body: CustomScrollView(
                key: const PageStorageKey<String>('anchored'),
                controller: controller,
                slivers: [
                  for (var s = 0; s < sections.length; s++) ...[
                    SliverToBoxAdapter(
                      child: SizedBox(key: ValueKey('header$s'), height: 60),
                    ),
                    ResponsiveContentSliverGrid(
                      itemCount: sections[s],
                      anchor: anchor,
                      anchorId: s,
                      itemBuilder: (_, index) => ColoredBox(
                        key: ValueKey(s * 1000 + index),
                        color: Colors.blue,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    // Columns and row stride the album grid has at a viewport [width].
    (int, double) geometry(double width) {
      final pane = width - 2 * ContentLayout.padding(width);
      final grid = ContentLayout.albums(pane, GridArtworkSize.auto);
      return (grid.columns, grid.extent + grid.gap);
    }

    double viewportTop(WidgetTester tester) =>
        tester.getTopLeft(find.byType(CustomScrollView)).dy;

    void expectInFirstRow(WidgetTester tester, int key, double width) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
      final top = tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      expect(top, greaterThanOrEqualTo(viewportTop(tester) - 1));
      expect(top, lessThan(viewportTop(tester) + geometry(width).$2));
    }

    testWidgets('header plus grid keeps item 40 in the first row across '
        '1040→2000', (tester) async {
      final controller = await pumpGrids(
        tester,
        size: const Size(1040, 800),
        sections: [240],
      );
      final (columns, stride) = geometry(1040);
      controller.jumpTo(60 + (40 ~/ columns) * stride);
      await tester.pumpAndSettle();
      expectInFirstRow(tester, 40, 1040);

      tester.view.physicalSize = const Size(2000, 800);
      await tester.pumpAndSettle();
      expect(geometry(2000).$1, isNot(columns));
      expectInFirstRow(tester, 40, 2000);
      expect(tester.takeException(), isNull);
    });

    testWidgets('same column count with a wider tile keeps the leading item', (
      tester,
    ) async {
      final controller = await pumpGrids(
        tester,
        size: const Size(1040, 800),
        sections: [240],
      );
      final (columns, stride) = geometry(1040);
      controller.jumpTo(60 + (200 ~/ columns) * stride);
      await tester.pumpAndSettle();
      expectInFirstRow(tester, 200, 1040);

      tester.view.physicalSize = const Size(1100, 800);
      await tester.pumpAndSettle();
      expect(geometry(1100).$1, columns);
      expect(geometry(1100).$2, greaterThan(stride));
      expectInFirstRow(tester, 200, 1100);
      expect(tester.takeException(), isNull);
    });

    testWidgets('two sections with the edge on the second header keep that '
        "header's first item", (tester) async {
      final controller = await pumpGrids(
        tester,
        size: const Size(1040, 800),
        sections: [60, 60],
      );
      // Put the second header exactly at the top edge.
      final (columns, stride) = geometry(1040);
      final rows = (60 + columns - 1) ~/ columns;
      controller.jumpTo(60 + rows * stride - 12 + 24);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('header1'))).dy,
        closeTo(viewportTop(tester), 0.5),
      );

      tester.view.physicalSize = const Size(2000, 800);
      await tester.pumpAndSettle();
      expectInFirstRow(tester, 1000, 2000);
      expect(tester.takeException(), isNull);
    });
  });

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
    expect(find.byTooltip('Next Items'), findsOneWidget);
    await tester.tap(find.byTooltip('Next Items'));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    final offset = scrollable.position.pixels;
    expect(offset, greaterThan(0));
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, offset);
    expect(find.byTooltip('Previous Items'), findsOneWidget);
    tester.view.physicalSize = const Size(2200, 800);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Next Items'), findsNothing);
    expect(find.byTooltip('Previous Items'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
