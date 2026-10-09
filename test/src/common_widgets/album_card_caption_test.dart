import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/caption_tint_resolver.dart';
import 'package:navis/src/features/home/presentation/cover_colour_sampler.dart';
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

  testWidgets('Flat coverTint caption is a solid fill block, not a fade', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const sampled = Color(0xFFE53935);
    final field = CoverColourField.uniform(sampled);
    sharedCoverColourFieldCache.put('cover-1', field);
    addTearDown(sharedCoverColourFieldCache.clear);
    final theme = buildDarkTheme(Colors.teal, flat: true);
    final expected = captionTintFor(
      sampled,
      theme.extension<NavisColorStyleData>()!,
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
          theme: theme,
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(child: AlbumCard(album: album, extent: 160)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final solid = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey<String>('albumCardTintSolid')),
    );
    final decoration = solid.decoration as BoxDecoration;
    expect(decoration.gradient, isNull);
    expect(decoration.color, expected.fill);
    expect(
      find.byKey(const ValueKey<String>('albumCardTintFade')),
      findsNothing,
    );
  });
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
