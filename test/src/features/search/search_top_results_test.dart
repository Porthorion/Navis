import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/search/domain/deezer_search_boost.dart';
import 'package:navis/src/features/search/presentation/search_top_results.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

import '../../../helpers/queue_replace_spy.dart';
import '../../../helpers/test_database.dart';

const _artist = TopArtistResult(
  Artist(id: 'ar', name: 'Radiohead', albumCount: 9, coverArt: 'ar-art'),
);
const _album = TopAlbumResult(
  Album(id: 'al', name: 'Pablo Honey', artist: 'Radiohead', year: 1993),
);
const _song = TopSongResult(
  Song(
    id: 's',
    title: 'Creep',
    artist: 'Radiohead',
    album: 'Pablo Honey',
    duration: 238,
  ),
);

void main() {
  late QueueReplaceSpy queue;

  Future<void> pump(
    WidgetTester tester,
    List<SearchTopResult> tops, {
    bool desktop = false,
    Size size = const Size(400, 900),
    double textScale = 1,
    NavisShapeData? shape,
    List<Override> overrides = const <Override>[],
  }) async {
    if (!sqliteAvailable) return;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = createTestDatabase();
    queue = QueueReplaceSpy();
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          queueProvider.overrideWith(() => queue),
          subsonicApiProvider.overrideWithValue(null),
          ...overrides,
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(extensions: <ThemeExtension<dynamic>>[?shape]),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: SearchTopResultsSection(
                  topResults: tops,
                  desktopMode: desktop,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder key(String value) => find.byKey(ValueKey<String>(value));

  group('hero', () {
    testWidgets('artist: kind and album count, Shuffle as second action', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_artist]);
      expect(find.text('Radiohead'), findsOneWidget);
      expect(find.text('Artist · 9 albums'), findsOneWidget);
      expect(find.byTooltip('Play'), findsNothing); // a labelled button
      expect(find.text('Play'), findsOneWidget);
      expect(find.byTooltip('Shuffle'), findsOneWidget);
      expect(find.byTooltip('Like'), findsNothing);
      expect(find.byTooltip('More'), findsOneWidget);
    });

    testWidgets('artist without albums is just "Artist"', (tester) async {
      if (!sqliteAvailable) return;
      await pump(tester, [const TopArtistResult(Artist(id: 'a', name: 'X'))]);
      expect(find.text('Artist'), findsOneWidget);
    });

    testWidgets('album: kind and year, Shuffle as second action', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_album]);
      expect(find.text('Album · 1993'), findsOneWidget);
      expect(find.byTooltip('Shuffle'), findsOneWidget);
      expect(find.byTooltip('Like'), findsNothing);
    });

    testWidgets('song: album and duration, Like as second action', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_song]);
      expect(find.text('Song · Pablo Honey · 3:58'), findsOneWidget);
      expect(find.byTooltip('Like'), findsOneWidget);
      expect(find.byTooltip('Shuffle'), findsNothing);
    });

    testWidgets('a song without album or duration is just "Song"', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(tester, [const TopSongResult(Song(id: 's', title: 'Creep'))]);
      expect(find.text('Song'), findsOneWidget);
    });

    testWidgets('Play on a song plays it, and the card is one tap target', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_song]);
      await tester.tap(find.text('Play'));
      await tester.pump();
      expect(queue.lastReplaceIds, <String>['s']);
      queue.lastReplaceIds = null;
      await tester.tap(find.text('Creep'));
      await tester.pump();
      expect(queue.lastReplaceIds, <String>['s']);
      expect(
        find.bySemanticsLabel('Creep, Song · Pablo Honey · 3:58'),
        findsOneWidget,
      );
    });

    testWidgets('More opens the existing song menu with Add to Playlist', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_song]);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Add to Playlist'), findsOneWidget);
      expect(find.text('Play Next'), findsOneWidget);
    });

    testWidgets('More opens the artist menu', (tester) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_artist]);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Open Artist'), findsOneWidget);
    });

    for (final (setting, expected) in <(String, BoxShape)>[
      ('circle', BoxShape.circle),
      ('square', BoxShape.rectangle),
    ]) {
      testWidgets('the artist image follows Artist Card Shape ($setting)', (
        tester,
      ) async {
        if (!sqliteAvailable) return;
        await pump(
          tester,
          [_artist],
          overrides: [artistCardShapeProvider.overrideWithValue(setting)],
        );
        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: find.byType(CoverArtImage),
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration;
        expect(decoration.shape, expected);
      });
    }

    for (final (setting, square) in <(String, bool)>[
      ('square', true),
      ('rounded', false),
    ]) {
      testWidgets('the album cover follows Artwork Shape ($setting)', (
        tester,
      ) async {
        if (!sqliteAvailable) return;
        await pump(
          tester,
          [_album],
          overrides: [coverArtShapeProvider.overrideWithValue(setting)],
        );
        final radius = tester
            .widget<HeroCoverArt>(find.byType(HeroCoverArt))
            .borderRadius;
        expect(radius == BorderRadius.zero, square);
      });
    }

    testWidgets('the song cover uses the cover shape role', (tester) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_song]);
      expect(
        tester.widget<CoverArtImage>(find.byType(CoverArtImage)).shape,
        ArtworkShapeRole.cover,
      );
    });

    for (final style in <NavisShapeData>[
      NavisShapeData.square,
      NavisShapeData.soft,
    ]) {
      testWidgets(
        'the card corners follow Corner Style (${style.style.name})',
        (tester) async {
          if (!sqliteAvailable) return;
          await pump(tester, [_song], shape: style);
          await tester.pumpAndSettle();
          final decoration =
              tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: key('search-top-result-0'),
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration!
                  as BoxDecoration;
          expect(decoration.borderRadius, style.lgAll);
        },
      );
    }

    testWidgets('tints flat from the cover colour, plain until it resolves', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      Color? fill() =>
          (tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: key('search-top-result-0'),
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color;
      await pump(tester, [_artist]);
      final plain = fill();
      expect(
        plain,
        Theme.of(tester.element(find.byType(Scaffold)))
            .colorScheme
            .surfaceContainerHigh,
      );
      await pump(
        tester,
        [_artist],
        overrides: [
          artworkSeedColorProvider('ar-art')
              .overrideWith((ref) async => 0xFFFF0000),
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(fill(), isNot(plain));
      expect(fill()!.r, greaterThan(fill()!.b));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('layout', () {
    testWidgets('one top is the hero alone', (tester) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_artist]);
      expect(key('search-top-result-0'), findsOneWidget);
      expect(key('search-top-result-1'), findsNothing);
    });

    testWidgets('mobile: the tiles sit side by side under the hero', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_artist, _album, _song]);
      final hero = tester.getRect(key('search-top-result-0'));
      final first = tester.getRect(key('search-top-result-1'));
      final second = tester.getRect(key('search-top-result-2'));
      expect(hero.width, closeTo(400 - 32, 0.5));
      expect(first.top, greaterThanOrEqualTo(hero.bottom));
      expect(second.top, first.top);
      expect(second.left, greaterThan(first.right));
      expect(first.width, closeTo(second.width, 0.5));
    });

    testWidgets('mobile: a single tile takes half the width, on the left', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_artist, _album]);
      final hero = tester.getRect(key('search-top-result-0'));
      final tile = tester.getRect(key('search-top-result-1'));
      expect(tile.left, hero.left);
      expect(tile.width, lessThan(hero.width / 2));
    });

    testWidgets('desktop: hero and tiles share a row at 2 : 1 : 1', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(
        tester,
        [_artist, _album, _song],
        desktop: true,
        size: const Size(1200, 700),
      );
      final hero = tester.getRect(key('search-top-result-0'));
      final first = tester.getRect(key('search-top-result-1'));
      final second = tester.getRect(key('search-top-result-2'));
      expect(first.top, hero.top);
      expect(second.top, hero.top);
      expect(first.bottom, hero.bottom);
      expect(hero.width, closeTo(first.width * 2, 0.5));
      expect(first.width, closeTo(second.width, 0.5));
    });

    testWidgets('desktop: missing tiles do not stretch the hero', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_artist], desktop: true, size: const Size(1200, 700));
      final hero = tester.getRect(key('search-top-result-0'));
      expect(hero.width, closeTo((1200 - 32 - 24) / 2, 1));
    });

    testWidgets('long titles ellipsize without overflow at 320 px, 1.3x', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      const long =
          'An Extremely Long Title That Goes On And On Forever And Ever Amen';
      await pump(
        tester,
        [
          const TopAlbumResult(Album(id: 'a', name: long, year: 1999)),
          const TopSongResult(
            Song(id: 's', title: long, album: long, duration: 61),
          ),
          const TopArtistResult(Artist(id: 'r', name: long, albumCount: 3)),
        ],
        size: const Size(320, 900),
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('long titles do not overflow on desktop 800 px', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      const long =
          'An Extremely Long Title That Goes On And On Forever And Ever Amen';
      await pump(
        tester,
        [
          const TopAlbumResult(Album(id: 'a', name: long, year: 1999)),
          const TopSongResult(Song(id: 's', title: long, album: long)),
          const TopArtistResult(Artist(id: 'r', name: long, albumCount: 3)),
        ],
        desktop: true,
        size: const Size(800, 600),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('remote results keep their Remote label and play', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(
        tester,
        [
          const TopSongResult(
            Song(id: 'ext-deezer-song-1', title: 'Creep', isExternal: true),
          ),
          const TopAlbumResult(
            Album(id: 'ext-deezer-album-2', name: 'Pablo', isExternal: true),
          ),
          const TopArtistResult(
            Artist(id: 'ext-deezer-artist-3', name: 'Radiohead'),
          ),
        ],
        desktop: true,
        size: const Size(1200, 700),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(RemoteSourceIndicator.semanticsKey), findsNWidgets(3));
      // No Like for a song that is not in the library.
      expect(find.byTooltip('Like'), findsNothing);
    });

    testWidgets('three albums (Albums filter): hero and two tiles', (
      tester,
    ) async {
      if (!sqliteAvailable) return;
      await pump(tester, [
        _album,
        const TopAlbumResult(Album(id: 'b', name: 'The Bends', year: 1995)),
        const TopAlbumResult(Album(id: 'c', name: 'OK Computer', year: 1997)),
      ]);
      expect(find.text('Album · 1993'), findsOneWidget);
      expect(find.text('Album · 1995'), findsOneWidget);
      expect(find.text('Album · 1997'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
    });

    testWidgets('a tile opens its result like the row does', (tester) async {
      if (!sqliteAvailable) return;
      await pump(tester, [_artist, _album, _song]);
      await tester.tap(find.text('Creep'));
      await tester.pump();
      expect(queue.lastReplaceIds, <String>['s']);
    });
  });
}
