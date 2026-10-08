import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/album_card_caption_variant.dart';
import 'package:navis/src/common_widgets/responsive_content_grid.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/theme/navis_theme.dart';

final List<AlbumsTableData> _albums = List<AlbumsTableData>.generate(
  6,
  (i) => AlbumsTableData(
    id: 'album-$i',
    name: 'Album $i with a deliberately long title that wraps over lines',
    artistName: 'Artist $i',
    artists: const [],
    songsHydrated: true,
    isProvisional: false,
    isExternal: false,
  ),
);

Future<void> _pump(
  WidgetTester tester,
  AlbumCardCaptionVariant variant,
  ThemeData theme,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subsonicApiProvider.overrideWithValue(null),
        coverArtShapeProvider.overrideWithValue('rounded'),
        gridArtworkSizeProvider.overrideWithValue(GridArtworkSize.auto),
        albumCardCaptionVariantProvider.overrideWith(
          () => _FixedVariant(variant),
        ),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              ResponsiveContentSliverGrid(
                itemCount: _albums.length,
                itemBuilder: (context, index) =>
                    AlbumCard(album: _albums[index]),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}

class _FixedVariant extends AlbumCardCaptionVariantNotifier {
  new(this.variant);

  final AlbumCardCaptionVariant variant;

  @override
  AlbumCardCaptionVariant build() => variant;
}

void main() {
  final themes = <String, ThemeData>{
    'light': buildLightTheme(defaultColorSchemeSeedColor),
    'dark': buildDarkTheme(defaultColorSchemeSeedColor),
  };

  for (final variant in AlbumCardCaptionVariant.values) {
    for (final entry in themes.entries) {
      testWidgets('${variant.name} grid lays out in ${entry.key}', (
        tester,
      ) async {
        await _pump(tester, variant, entry.value);
        expect(tester.takeException(), isNull);

        final firstTitle = find.textContaining('Album 0');
        expect(firstTitle, findsOneWidget);
        final titleRect = tester.getRect(firstTitle);
        final coverRect = tester.getRect(
          find.byKey(const ValueKey('albumCardTapTarget')).first,
        );

        switch (variant) {
          case AlbumCardCaptionVariant.overlayFade:
            expect(
              find.byKey(const ValueKey<String>('albumCardTitleSurfaceFade')),
              findsWidgets,
            );
            expect(titleRect.bottom, lessThanOrEqualTo(coverRect.bottom));
          case AlbumCardCaptionVariant.below:
            expect(titleRect.top, greaterThanOrEqualTo(coverRect.bottom));
            expect(
              find.byKey(const ValueKey<String>('albumCardTitleSurfaceFade')),
              findsNothing,
            );
            final text = tester.widget<Text>(firstTitle);
            expect(text.style!.color, entry.value.colorScheme.onSurface);
          case AlbumCardCaptionVariant.band:
            final band = tester.widget<ColoredBox>(
              find.byKey(const ValueKey<String>('albumCardBand')).first,
            );
            expect(band.color.a, 1);
            expect(band.color, entry.value.scaffoldBackgroundColor);
            final bandRect = tester.getRect(
              find.byKey(const ValueKey<String>('albumCardBand')).first,
            );
            expect(bandRect.contains(titleRect.center), isTrue);
            expect(bandRect.bottom, coverRect.bottom);
          case AlbumCardCaptionVariant.darkScrim:
            final text = tester.widget<Text>(firstTitle);
            expect(text.style!.color, Colors.white);
            expect(text.style!.shadows, isNotEmpty);
            final scrim = tester.widget<DecoratedBox>(
              find.byKey(const ValueKey<String>('albumCardDarkScrim')).first,
            );
            final gradient =
                (scrim.decoration as BoxDecoration).gradient! as LinearGradient;
            expect(gradient.colors.last.a, closeTo(0.75, 0.01));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('below caption fits at 200% text scale', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subsonicApiProvider.overrideWithValue(null),
          coverArtShapeProvider.overrideWithValue('rounded'),
          gridArtworkSizeProvider.overrideWithValue(GridArtworkSize.auto),
          albumCardCaptionVariantProvider.overrideWith(
            () => _FixedVariant(AlbumCardCaptionVariant.below),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                ResponsiveContentSliverGrid(
                  itemCount: _albums.length,
                  itemBuilder: (context, index) =>
                      AlbumCard(album: _albums[index]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
  });
}
