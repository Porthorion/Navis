import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/responsive_content_grid.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/home/presentation/cover_colour_worker.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
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

Future<void> _pump(WidgetTester tester, ThemeData theme) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subsonicApiProvider.overrideWithValue(null),
        coverArtShapeProvider.overrideWithValue('rounded'),
        gridArtworkSizeProvider.overrideWithValue(GridArtworkSize.auto),
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

void main() {
  final themes = <String, ThemeData>{
    'light': buildLightTheme(defaultColorSchemeSeedColor),
    'dark': buildDarkTheme(defaultColorSchemeSeedColor),
  };

  for (final entry in themes.entries) {
    testWidgets('caption fallback stays over the cover in ${entry.key}', (
      tester,
    ) async {
      await _pump(tester, entry.value);
      expect(tester.takeException(), isNull);

      final firstTitle = find.textContaining('Album 0');
      expect(firstTitle, findsOneWidget);
      final titleRect = tester.getRect(firstTitle);
      final coverRect = tester.getRect(
        find.byKey(const ValueKey('albumCardTapTarget')).first,
      );
      expect(
        find.byKey(const ValueKey<String>('albumCardTitleSurfaceFade')),
        findsWidgets,
      );
      final text = tester.widget<Text>(firstTitle);
      expect(text.style!.color, entry.value.colorScheme.onSurface);
      expect(titleRect.bottom, lessThanOrEqualTo(coverRect.bottom));
    });

    testWidgets('coverTint paints the derived fill in ${entry.key}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const sampled = Color(0xFFE53935);
      final field = CoverColourField.uniform(sampled);
      // A cover sampled earlier paints its tint on the first frame.
      sharedCoverColourFieldCache.put('cover-1', field);
      addTearDown(sharedCoverColourFieldCache.clear);
      final expected = captionTintFor(
        sampled,
        entry.value.extension<NavisColorStyleData>() ??
            NavisColorStyleData(
              style: NavisColorStyle.neutral,
              dark: entry.value.brightness == Brightness.dark,
            ),
      );
      final album = AlbumsTableData(
        id: 'tinted',
        name: 'Tinted',
        artistName: 'Artist',
        artists: const [],
        songsHydrated: true,
        isProvisional: false,
        isExternal: false,
        coverArt: 'cover-1',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subsonicApiProvider.overrideWithValue(null),
            coverArtShapeProvider.overrideWithValue('rounded'),
            coverColourWorkerProvider.overrideWithValue(
              InlineCoverColourWorker(),
            ),
            coverColourFieldProvider.overrideWith((ref, id) async => field),
          ],
          child: MaterialApp(
            theme: entry.value,
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(child: AlbumCard(album: album, extent: 160)),
            ),
          ),
        ),
      );
      // Worker result, dispatcher frame, then the tint animation.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final textFade = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey<String>('albumCardTintText')),
      );
      final gradient =
          (textFade.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.colors.last, expected.fill);
      expect(gradient.colors.first.a, closeTo(0.85, 0.01));
      final title = tester.widget<Text>(find.text('Tinted'));
      expect(title.style!.color, expected.text);
      final subtitle = tester.widget<Text>(find.text('Artist'));
      expect(subtitle.style!.color, expected.subtext);
      expect(captionContrast(expected.text, expected.fill), greaterThan(4.5));
      expect(
        find.byKey(const ValueKey<String>('albumCardTitleSurfaceFade')),
        findsNothing,
      );
    });
  }
}
