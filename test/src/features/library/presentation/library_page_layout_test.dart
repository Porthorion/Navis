import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/artist_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/list_filter_field.dart';
import 'package:navis/src/common_widgets/responsive_content_grid.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

const _sortKey = ValueKey<String>('sortUnderTest');

/// The Artists tab reserves this much at the trailing edge for its letter rail.
const double _railInset = 28;

Widget _row({
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
  bool alignWithGrid = true,
}) => MaterialApp(
  theme: testTheme(),
  localizationsDelegates: navisLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: Directionality(textDirection: direction, child: child!),
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: LibrarySortFilterRow<int>(
        alignWithGrid: alignWithGrid,
        sortKey: _sortKey,
        sortLabel: 'Sort',
        sortValue: 1,
        sortItems: const <DropdownMenuItem<int>>[
          DropdownMenuItem(value: 1, child: Text('One')),
          DropdownMenuItem(value: 2, child: Text('Two')),
        ],
        onSortChanged: (_) {},
        downloadedOnly: false,
        onDownloadedOnlyChanged: (_) {},
      ),
    ),
  ),
);

void main() {
  group('LibrarySortFilterRow', () {
    for (final (size, inset) in <(Size, double)>[
      (const Size(1920, 1080), 24),
      (const Size(412, 915), 12),
    ]) {
      testWidgets('${size.width.toInt()} px: chip and sort sit on the page '
          'insets', (tester) async {
        setAdaptiveTestViewport(tester, size);
        await tester.pumpWidget(_row());
        final sort = tester.getRect(find.byKey(_sortKey));
        final chip = tester.getRect(find.byType(FilterChip));
        expect(sort.right, size.width - inset);
        expect(chip.left, inset);
        expect(sort.width, lessThanOrEqualTo(280));
        expect(sort.left, greaterThan(chip.right));
      });
    }

    testWidgets('a wide window gives the sort its full 280 px', (tester) async {
      setAdaptiveTestViewport(tester, const Size(1920, 1080));
      await tester.pumpWidget(_row());
      expect(tester.getSize(find.byKey(_sortKey)).width, 280);
    });

    testWidgets('above a list the edges sit on the 12 px list inset', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(1920, 1080));
      await tester.pumpWidget(_row(alignWithGrid: false));
      expect(tester.getRect(find.byKey(_sortKey)).right, 1920 - 12);
      expect(tester.getRect(find.byType(FilterChip)).left, 12);
    });

    testWidgets('right to left mirrors the edges', (tester) async {
      setAdaptiveTestViewport(tester, const Size(1920, 1080));
      await tester.pumpWidget(_row(direction: TextDirection.rtl));
      expect(tester.getRect(find.byKey(_sortKey)).left, 24);
      expect(tester.getRect(find.byType(FilterChip)).right, 1920 - 24);
    });

    testWidgets('large text stacks the controls', (tester) async {
      setAdaptiveTestViewport(tester, const Size(1920, 1080));
      await tester.pumpWidget(_row(textScale: 1.5));
      expect(
        tester.getTopLeft(find.byKey(_sortKey)).dy,
        greaterThan(tester.getBottomLeft(find.byType(FilterChip)).dy),
      );
    });
  });

  group('ListFilterField', () {
    for (final (size, inset) in <(Size, double)>[
      (const Size(1920, 1080), 24),
      (const Size(412, 915), 12),
    ]) {
      testWidgets('${size.width.toInt()} px: aligned with the chip and sort', (
        tester,
      ) async {
        setAdaptiveTestViewport(tester, size);
        await tester.pumpWidget(
          MaterialApp(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  ListFilterField(
                    controller: TextEditingController(),
                    hint: 'Search',
                    onChanged: (_) {},
                    onClear: () {},
                    alignWithContent: true,
                  ),
                  LibrarySortFilterRow<int>(
                    sortKey: _sortKey,
                    sortLabel: 'Sort',
                    sortValue: 1,
                    sortItems: const <DropdownMenuItem<int>>[
                      DropdownMenuItem(value: 1, child: Text('One')),
                    ],
                    onSortChanged: (_) {},
                    downloadedOnly: false,
                    onDownloadedOnlyChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        final field = tester.getRect(find.byType(TextField));
        expect(field.left, inset);
        expect(field.right, size.width - inset);
        expect(field.left, tester.getRect(find.byType(FilterChip)).left);
        expect(field.right, tester.getRect(find.byKey(_sortKey)).right);
      });
    }
  });

  group('Artist grid tile', () {
    final artists = <ArtistsTableData>[
      for (var i = 0; i < 9; i++)
        ArtistsTableData(
          isProvisional: false,
          isExternal: false,
          id: 'ar-$i',
          name: 'Artist $i',
          albumCount: 1,
        ),
    ];

    Future<List<Rect>> avatars(WidgetTester tester, Size size) async {
      setAdaptiveTestViewport(tester, size);
      final database = createTestDatabase();
      addTearDown(database.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...withTestDatabase(database),
            subsonicApiProvider.overrideWithValue(null),
            coverArtShapeProvider.overrideWithValue('rounded'),
            artistCardShapeProvider.overrideWithValue('circle'),
          ],
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: <Widget>[
                  ResponsiveContentSliverGrid(
                    artists: true,
                    trailingInset: _railInset,
                    itemCount: artists.length,
                    itemBuilder: (context, i) =>
                        ArtistCard.grid(artist: artists[i]),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return <Rect>[
        for (final element in find.byType(CoverArtImage).evaluate())
          tester.getRect(find.byWidget(element.widget)),
      ];
    }

    for (final size in <Size>[
      const Size(360, 800),
      const Size(375, 812),
      const Size(390, 844),
      const Size(412, 915),
      const Size(1920, 1080),
    ]) {
      testWidgets('${size.width.toInt()} px: the avatar fills its cell and '
          'the grid gap is the only gutter', (tester) async {
        final rects = await avatars(tester, size);
        final grid = ContentLayout.artists(
          size.width - ContentLayout.padding(size.width) * 2 - _railInset,
          GridArtworkSize.auto,
        );
        final gap = ContentLayout.gap(size.width);
        // Avatars are the cell size, in one even row-major grid.
        for (final rect in rects) {
          expect(rect.width, closeTo(grid.extent, 0.01));
          expect(rect.height, closeTo(grid.extent, 0.01));
        }
        final first = rects.where((r) => r.top == rects.first.top).toList()
          ..sort((a, b) => a.left.compareTo(b.left));
        expect(first.length, grid.columns.clamp(1, rects.length));
        for (var i = 1; i < first.length; i++) {
          expect(first[i].left - first[i - 1].right, closeTo(gap, 0.01));
        }
        // On a phone the grid fills the pane up to the page inset.
        if (size.width < 600) {
          final inset = ContentLayout.padding(size.width);
          expect(first.first.left, closeTo(inset, 0.01));
          expect(
            first.last.right,
            closeTo(size.width - inset - _railInset, 0.01),
          );
          expect(grid.columns, 3);
        }
      });
    }
  });
}
