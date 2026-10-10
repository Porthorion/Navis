import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/artwork_scrim.dart';
import 'package:navis/src/common_widgets/marquee_text.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/caption_tint_resolver.dart';
import 'package:navis/src/features/home/presentation/cover_colour_sampler.dart';
import 'package:navis/src/common_widgets/responsive_content_grid.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/features/settings/domain/album_title_shade.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/home/presentation/cover_colour_worker.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
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

final AlbumsTableData _longAlbum = AlbumsTableData(
  id: 'long',
  name: 'An extraordinarily long album title that cannot possibly fit',
  artistName: 'Artist with a name that is long enough to need an ellipsis',
  artists: const [],
  songsHydrated: true,
  isProvisional: false,
  isExternal: false,
  coverArt: 'cover-1',
);

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme, {
  bool coloredShade = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subsonicApiProvider.overrideWithValue(null),
        coverArtShapeProvider.overrideWithValue('rounded'),
        albumTitleShadeModeProvider.overrideWithValue(
          coloredShade ? AlbumTitleShade.color : AlbumTitleShade.classic,
        ),
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

  testWidgets(
    'revision refresh waits for artwork and scrolling, keeps tint through worker dispatch',
    (tester) async {
      clearCaptionTintMemo();
      sharedCoverColourFieldCache.clear();
      addTearDown(clearCaptionTintMemo);
      addTearDown(sharedCoverColourFieldCache.clear);
      final old = CoverColourField.uniform(const Color(0xFFE53935));
      final fresh = CoverColourField.uniform(const Color(0xFF1976D2));
      sharedCoverColourFieldCache.put('cover', old);
      final gate = Completer<CoverColourField?>();
      var decodes = 0;
      final sampler = CoverColourSampler(
        decode: (id, {revision = 0}) {
          expectSync(revision, 1);
          decodes++;
          return gate.future;
        },
        cache: sharedCoverColourFieldCache,
        coordinator: CoverArtLoadCoordinator(
          maxActiveDownloads: 2,
          criticalReserve: 0,
        ),
      );
      addTearDown(sampler.dispose);
      final worker = _GatedTintWorker();
      final revision = ValueNotifier<int>(0);
      final ready = ValueNotifier<bool>(true);
      final scroll = ScrollController();
      addTearDown(revision.dispose);
      addTearDown(ready.dispose);
      addTearDown(scroll.dispose);
      final theme = buildDarkTheme(defaultColorSchemeSeedColor);
      final style = theme.extension<NavisColorStyleData>()!;
      final expectedOld = captionTintFor(old.bottomRowAverage, style).fill;
      final expectedNew = captionTintFor(fresh.bottomRowAverage, style).fill;
      Color fill() {
        final box = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey<String>('albumCardTintText')),
        );
        return ((box.decoration as BoxDecoration).gradient! as LinearGradient)
            .colors
            .last;
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            albumTitleShadeModeProvider.overrideWithValue(
              AlbumTitleShade.color,
            ),
            coverColourSamplerProvider.overrideWithValue(sampler),
            coverColourWorkerProvider.overrideWithValue(worker),
          ],
          child: MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: revision,
                      builder: (context, rev, _) => SizedBox(
                        width: 160,
                        height: 160,
                        child: Stack(
                          children: [
                            AlbumCardLabel(
                              title: 'Cover',
                              subtitle: 'Artist',
                              coverArtId: 'cover',
                              coverArtRevision: rev,
                              coverReady: ready,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fill(), expectedOld);
      expect(decodes, 0);
      ready.value = false;
      revision.value = 1;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(decodes, 0);
      expect(fill(), expectedOld);
      // The existing scroll/settle gate also applies to revision refreshes.
      scroll.position.isScrollingNotifier.value = true;
      ready.value = true;
      await tester.pump(const Duration(milliseconds: 300));
      expect(decodes, 0);
      scroll.position.isScrollingNotifier.value = false;
      await tester.pump(kCoverTintSettleDelay);
      await tester.pump();
      expect(decodes, 1);
      expect(fill(), expectedOld);
      worker.hold = true;
      gate.complete(fresh);
      await tester.pump();
      await tester.pump();
      expect(worker.pending, isNotNull);
      expect(fill(), expectedOld);
      scroll.position.isScrollingNotifier.value = true;
      worker.pending!.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      // Arrival during scrolling applies instantly through the dispatcher.
      expect(fill(), expectedNew);
      expect(decodes, 1);
      scroll.position.isScrollingNotifier.value = false;
      await tester.pumpWidget(const SizedBox());
    },
  );

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
            albumTitleShadeModeProvider.overrideWithValue(
              AlbumTitleShade.color,
            ),
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
      expect(gradient.colors.first.a, closeTo(1, 0.01));
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

  testWidgets('the classic fade never asks for cover colours', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final worker = _CountingTintWorker();
    final album = AlbumsTableData(
      id: 'classic',
      name: 'Classic',
      artistName: 'Artist',
      artists: const [],
      songsHydrated: true,
      isProvisional: false,
      isExternal: false,
      coverArt: 'cover-1',
    );
    var fieldRequests = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subsonicApiProvider.overrideWithValue(null),
          coverArtShapeProvider.overrideWithValue('rounded'),
          albumTitleShadeModeProvider.overrideWithValue(
            AlbumTitleShade.classic,
          ),
          coverColourWorkerProvider.overrideWithValue(worker),
          coverColourFieldProvider.overrideWith((ref, id) async {
            fieldRequests++;
            return CoverColourField.uniform(const Color(0xFFE53935));
          }),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(Colors.teal),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(child: AlbumCard(album: album, extent: 160)),
          ),
        ),
      ),
    );
    await tester.pump(kCoverTintSettleDelay * 3);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const ValueKey<String>('albumCardTitleSurfaceFade')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('albumCardCaptionLayer')),
      findsNothing,
    );
    expect(fieldRequests, 0);
    expect(worker.requests, 0);
  });

  group('Flat text over artwork', () {
    final album = AlbumsTableData(
      id: 'below',
      name: 'Below',
      artistName: 'Artist',
      artists: const [],
      songsHydrated: true,
      isProvisional: false,
      isExternal: false,
      coverArt: 'cover-1',
    );

    Future<_CountingTintWorker> pumpFlat(
      WidgetTester tester, {
      required AlbumTitleShade mode,
      AlbumsTableData? card,
      FlatAreas areas = const FlatAreas(),
      double textScale = 1,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final worker = _CountingTintWorker();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subsonicApiProvider.overrideWithValue(null),
            coverArtShapeProvider.overrideWithValue('rounded'),
            albumTitleShadeModeProvider.overrideWithValue(mode),
            coverColourWorkerProvider.overrideWithValue(worker),
            coverColourFieldProvider.overrideWith(
              (ref, id) async =>
                  CoverColourField.uniform(const Color(0xFFE53935)),
            ),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(Colors.teal, flat: true, flatAreas: areas),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: AlbumCard(album: card ?? album, extent: 160),
              ),
            ),
          ),
        ),
      );
      await tester.pump(kCoverTintSettleDelay * 3);
      await tester.pump(const Duration(milliseconds: 400));
      return worker;
    }

    for (final mode in AlbumTitleShade.values) {
      testWidgets('puts the caption below an unobstructed cover '
          '(shade: ${mode.name})', (tester) async {
        final worker = await pumpFlat(tester, mode: mode);

        final cover = tester.getRect(
          find.byKey(const ValueKey('albumCardTapTarget')),
        );
        final caption = find.byKey(
          const ValueKey<String>('albumCardCaptionBelow'),
        );
        expect(caption, findsOneWidget);
        final captionRect = tester.getRect(caption);
        expect(cover.size, const Size(160, 160));
        expect(captionRect.top, closeTo(cover.bottom, 0.01));
        final title = tester.getRect(find.text('Below'));
        expect(title.top, greaterThanOrEqualTo(cover.bottom));
        // Nothing is drawn over the art, and no cover colour is sampled.
        for (final key in <String>[
          'albumCardTitleSurfaceFade',
          'albumCardDarkShade',
          'albumCardTintFade',
          'albumCardTintText',
          'albumCardCaptionLayer',
        ]) {
          expect(find.byKey(ValueKey<String>(key)), findsNothing, reason: key);
        }
        expect(worker.requests, 0);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('keeps the overlay when only other areas are flat', (
      tester,
    ) async {
      await pumpFlat(
        tester,
        mode: AlbumTitleShade.classic,
        areas: const FlatAreas(artworkText: false),
      );

      expect(
        find.byKey(const ValueKey<String>('albumCardCaptionBelow')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('albumCardTitleSurfaceFade')),
        findsOneWidget,
      );
      expect(tester.getSize(find.byType(AlbumCard)), const Size(160, 160));
    });

    testWidgets('the caption is one line tall however long the title is', (
      tester,
    ) async {
      const key = ValueKey<String>('albumCardCaptionBelow');
      await pumpFlat(tester, mode: AlbumTitleShade.classic);
      final short = tester.getSize(find.byKey(key)).height;
      await pumpFlat(tester, mode: AlbumTitleShade.classic, card: _longAlbum);

      expect(tester.getSize(find.byKey(key)).height, short);
      final title = tester.widget<Text>(find.text(_longAlbum.name));
      expect(title.maxLines, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('caption height follows the text scale', (tester) async {
      const key = ValueKey<String>('albumCardCaptionBelow');
      await pumpFlat(tester, mode: AlbumTitleShade.classic);
      final normal = tester.getSize(find.byKey(key)).height;
      await pumpFlat(tester, mode: AlbumTitleShade.classic, textScale: 2);

      expect(tester.getSize(find.byKey(key)).height, greaterThan(normal));
      expect(tester.takeException(), isNull);
    });
  });

  group('dark shade', () {
    final album = AlbumsTableData(
      id: 'dark',
      name: 'Dark',
      artistName: 'Artist',
      artists: const [],
      songsHydrated: true,
      isProvisional: false,
      isExternal: false,
      coverArt: 'cover-1',
    );

    testWidgets('draws white text on the style scrim and samples nothing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final worker = _CountingTintWorker();
      var fieldRequests = 0;
      final theme = buildDarkTheme(Colors.teal, style: NavisColorStyle.pastel);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subsonicApiProvider.overrideWithValue(null),
            coverArtShapeProvider.overrideWithValue('rounded'),
            albumTitleShadeModeProvider.overrideWithValue(AlbumTitleShade.dark),
            coverColourWorkerProvider.overrideWithValue(worker),
            coverColourFieldProvider.overrideWith((ref, id) async {
              fieldRequests++;
              return CoverColourField.uniform(const Color(0xFFE53935));
            }),
          ],
          child: MaterialApp(
            theme: theme,
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(child: AlbumCard(album: album, extent: 160)),
            ),
          ),
        ),
      );
      await tester.pump(kCoverTintSettleDelay * 3);
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const ValueKey<String>('albumCardDarkShade')),
        findsOneWidget,
      );
      for (final key in <String>[
        'albumCardTitleSurfaceFade',
        'albumCardTintText',
        'albumCardCaptionLayer',
      ]) {
        expect(find.byKey(ValueKey<String>(key)), findsNothing, reason: key);
      }
      final scrim = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(ArtworkScrim),
          matching: find.byType(DecoratedBox),
        ),
      );
      final gradient =
          (scrim.decoration as BoxDecoration).gradient! as LinearGradient;
      final style = theme.extension<NavisColorStyleData>()!;
      expect(gradient.colors.first.a, 0);
      expect(gradient.colors.last.a, greaterThan(0.7));
      expect(
        gradient.colors.last.withValues(alpha: 1),
        style.artworkScrim.withValues(alpha: 1),
      );
      final title = tester.widget<Text>(find.text('Dark'));
      expect(title.style!.color!.withValues(alpha: 1), Colors.white);
      expect(
        captionContrast(title.style!.color!, gradient.colors.last),
        greaterThan(4.5),
      );
      expect(fieldRequests, 0);
      expect(worker.requests, 0);
      expect(tester.getSize(find.byType(AlbumCard)), const Size(160, 160));
    });

    testWidgets('a long title is one scrolling line over the cover', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subsonicApiProvider.overrideWithValue(null),
            coverArtShapeProvider.overrideWithValue('rounded'),
            albumTitleShadeModeProvider.overrideWithValue(AlbumTitleShade.dark),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(Colors.teal),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(child: AlbumCard(album: _longAlbum, extent: 160)),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byType(MarqueeText), findsOneWidget);
      final title = tester.getRect(find.text(_longAlbum.name));
      final card = tester.getRect(find.byType(AlbumCard));
      expect(title.height, lessThan(24));
      expect(title.bottom, lessThan(card.bottom));
      expect(tester.takeException(), isNull);
    });
  });

  group('colored shade', () {
    testWidgets('keeps a card square and overlays the tint', (tester) async {
      await _pump(
        tester,
        buildDarkTheme(defaultColorSchemeSeedColor),
        coloredShade: true,
      );

      expect(
        find.byKey(const ValueKey<String>('albumCardCaptionLayer')),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey<String>('albumCardCaptionBelow')),
        findsNothing,
      );
    });
  });
}

class _CountingTintWorker extends InlineCoverColourWorker {
  int requests = 0;

  @override
  Future<List<double>> captionTint(Color sampled, NavisColorStyleData style) {
    requests++;
    return super.captionTint(sampled, style);
  }
}

class _GatedTintWorker extends InlineCoverColourWorker {
  bool hold = false;
  Completer<void>? pending;

  @override
  Future<List<double>> captionTint(
    Color sampled,
    NavisColorStyleData style,
  ) async {
    if (hold) {
      pending = Completer<void>();
      await pending!.future;
    }
    return await super.captionTint(sampled, style);
  }
}
