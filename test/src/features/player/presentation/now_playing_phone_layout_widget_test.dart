import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/expandable_player_sheet.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/now_playing_phone_layout.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/now_playing_harness.dart';
import '../../../../helpers/test_database.dart';

const PlaybackSnapshot _song = PlaybackSnapshot(
  queueSongIds: <String>['song-1'],
  currentSongId: 'song-1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration(seconds: 42),
  duration: Duration(minutes: 3, seconds: 30),
  bufferedPosition: Duration(minutes: 1),
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

final PlaybackSnapshot _radio = _song.copyWith(
  radioStation: const RadioStationMetadata(
    stationId: 'radio-1',
    stationName: 'Night Drive FM',
    streamUrl: 'https://example.com/radio',
    nowPlayingTitle: 'Midnight Drive',
    nowPlayingArtist: 'The Night Owls',
  ),
);

const _item = MediaItem(
  id: 'song-1',
  title: 'Midnight Drive',
  artist: 'The Night Owls',
  album: 'City Lights',
);

const _arabic = MediaItem(
  id: 'song-1',
  title: 'ليلة في القاهرة الحبيبة والذكريات',
  artist: 'أم كلثوم وفرقة الموسيقى العربية',
  album: 'أجمل الأغاني القديمة المختارة',
);

const _japanese = MediaItem(
  id: 'song-1',
  title: '夜に駆ける 〜 真夜中のドライブ',
  artist: '宇多田ヒカル・米津玄師',
  album: '東京の夜景とメロディ',
);

const _statusBar = 24.0;
const _handle = 18.0;

/// Phone sizes under test and the golden each one writes.
const _phones = <(String, Size)>[
  ('360x640', Size(360, 640)),
  ('390x844', Size(390, 844)),
  ('412x915', Size(412, 915)),
  ('411x960', Size(411, 960)),
];

/// Pumps the Now Playing screen the way an Android phone shows it: 24 dp
/// status bar and [bottomInset] of navigation (24 dp gesture, 48 dp buttons).
Future<void> _pump(
  WidgetTester tester,
  Size size, {
  double bottomInset = 24,
  double textScale = 1,
  PlaybackSnapshot playback = _song,
  MediaItem item = _item,
  TextTheme? textTheme,
  VoidCallback? onCollapse,
}) async {
  setAdaptiveTestViewport(tester, size);
  final padding = FakeViewPadding(top: _statusBar, bottom: bottomInset);
  tester.view
    ..padding = padding
    ..viewPadding = padding;
  addTearDown(() {
    tester.view
      ..resetPadding()
      ..resetViewPadding();
  });
  final container = createNowPlayingContainer(
    overrides: [currentMediaItemProvider.overrideWithValue(AsyncData(item))],
  );
  container.read(nowPlayingTestPlaybackProvider.notifier).state = playback;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          textTheme: textTheme,
        ),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          // With a collapse hook the screen sits in the real sheet, whose
          // swipe-down drag is what the Now Playing body must never block.
          body: onCollapse == null
              ? const NowPlayingScreen()
              : ExpandablePlayerSheet(
                  miniPlayer: const SizedBox.shrink(),
                  fullPlayer: const NowPlayingScreen(),
                  isExpanded: true,
                  onExpand: () {},
                  onCollapse: onCollapse,
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _byType(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

Size _size(WidgetTester tester, String type) =>
    tester.getSize(_byType(type).first);

Rect _rect(WidgetTester tester, Finder finder) => tester.getRect(finder.first);

NowPlayingPhoneLayout _model(
  WidgetTester tester,
  Size size,
  double scale, {
  bool radio = false,
}) => NowPlayingPhoneLayout.compute(
  width: size.width,
  height: _size(tester, '_NowPlayingBody').height,
  textScaler: TextScaler.linear(scale),
  isRadio: radio,
);

void main() {
  group('phone layout renders as modelled', () {
    for (final (name, size) in _phones) {
      for (final inset in [24.0, 48.0]) {
        testWidgets('$name with $inset dp navigation', (tester) async {
          await _pump(tester, size, bottomInset: inset);
          expect(tester.takeException(), isNull);

          final body = _rect(tester, _byType('_NowPlayingBody'));
          expect(body.height, size.height - _statusBar - _handle - inset);
          final l = _model(tester, size, 1);

          // The model's block heights are the rendered ones.
          expect(_size(tester, '_TrackInfo').height, closeTo(l.titleBlock, 1));
          if (l.showInfo) {
            expect(
              _size(tester, '_NowPlayingInfoPanel').height,
              closeTo(l.infoBlock, 1),
            );
          }
          expect(_size(tester, '_SeekBar').height, closeTo(l.seekBlock, 1));
          expect(
            _size(tester, '_TransportControls').height,
            closeTo(l.transportBlock, 1),
          );
          expect(_size(tester, '_ActionRow').height, closeTo(l.actionBlock, 1));

          // The cover is an exact square of the computed size, centred.
          final cover = _rect(tester, find.byType(CoverArtImage));
          expect(cover.width, closeTo(l.artSize, 0.5));
          expect(cover.height, closeTo(l.artSize, 0.5));
          expect(cover.center.dx, closeTo(size.width / 2, 0.5));

          // Controls are pinned to the bottom: the action row ends one
          // bottom gap above the body and nothing is clipped.
          final actions = _rect(tester, _byType('_ActionRow'));
          expect(actions.bottom, closeTo(body.bottom - l.bottom, 1));
          final play = _rect(tester, find.byTooltip('Pause'));
          expect(play.bottom, lessThan(actions.top));
          for (final button in tester.widgetList(
            find.descendant(
              of: _byType('_ActionRow'),
              matching: find.byType(IconButton),
            ),
          )) {
            final rect = tester.getRect(find.byWidget(button));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(rect.bottom, lessThanOrEqualTo(size.height - inset));
          }
          expect(
            _rect(tester, find.byTooltip('Pause')).center.dx,
            closeTo(size.width / 2, 0.5),
          );

          // Order top to bottom, no overlap.
          final title = _rect(tester, _byType('_TrackInfo'));
          expect(cover.bottom, lessThanOrEqualTo(title.top + 0.5));
          expect(
            title.bottom,
            lessThanOrEqualTo(_rect(tester, _byType('_SeekBar')).top),
          );
          expect(
            _rect(tester, _byType('_SeekBar')).bottom,
            lessThanOrEqualTo(play.top),
          );
        }, skip: !sqliteAvailable);
      }
    }
  });

  testWidgets('short phones fold the album into the artist line', (
    tester,
  ) async {
    await _pump(tester, const Size(360, 640));
    expect(_model(tester, const Size(360, 640), 1).foldAlbum, isTrue);
    expect(find.text(' · '), findsOneWidget);
    expect(find.text('The Night Owls'), findsOneWidget);
    expect(find.text('City Lights'), findsOneWidget);
    final artist = _rect(tester, find.text('The Night Owls'));
    final album = _rect(tester, find.text('City Lights'));
    expect(album.center.dy, closeTo(artist.center.dy, 1));
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('tall phones step the title and Play button up', (tester) async {
    await _pump(tester, const Size(411, 960));
    final title = tester.widget<Text>(find.text('Midnight Drive'));
    expect(title.style?.fontSize, 24);
    final artist = tester.widget<Text>(find.text('The Night Owls'));
    expect(artist.style?.fontSize, 17);
    expect(find.text(' · '), findsNothing);
    expect(find.text('City Lights'), findsOneWidget);
    expect(
      tester
          .getSize(
            find.descendant(
              of: find.byTooltip('Pause'),
              matching: find.byType(FilledButton),
            ),
          )
          .height,
      62,
    );
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('normal phones keep the current type sizes', (tester) async {
    await _pump(tester, const Size(390, 844));
    final title = tester.widget<Text>(find.text('Midnight Drive'));
    expect(title.style?.fontSize, 20);
    final artist = tester.widget<Text>(find.text('The Night Owls'));
    expect(artist.style?.fontSize, 15);
    expect(
      tester
          .getSize(
            find.descendant(
              of: find.byTooltip('Pause'),
              matching: find.byType(FilledButton),
            ),
          )
          .height,
      54,
    );
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('radio uses the same cover rule without seek or actions', (
    tester,
  ) async {
    const size = Size(390, 844);
    await _pump(tester, size, playback: _radio);
    expect(tester.takeException(), isNull);
    expect(_byType('_SeekBar'), findsNothing);
    expect(_byType('_ActionRow'), findsNothing);
    final l = _model(tester, size, 1, radio: true);
    final body = _rect(tester, _byType('_NowPlayingBody'));
    final cover = _rect(
      tester,
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_RadioCoverArt',
      ),
    );
    expect(cover.width, closeTo(l.artSize, 0.5));
    expect(cover.height, closeTo(l.artSize, 0.5));
    final transport = _rect(tester, _byType('_TransportControls'));
    expect(transport.bottom, closeTo(body.bottom - l.bottom, 1));
  }, skip: !sqliteAvailable);

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'long radio artists stay on one line with Live visible at ${scale}x',
      (tester) async {
        const names = [
          'The First Very Long Radio Artist Name',
          'The Second Very Long Radio Artist Name',
          'The Third Very Long Radio Artist Name',
        ];
        const size = Size(360, 640);
        await _pump(
          tester,
          size,
          textScale: scale,
          playback: _radio.copyWith(
            radioStation: RadioStationMetadata(
              stationId: 'radio-1',
              stationName: 'Night Drive FM',
              streamUrl: 'https://example.com/radio',
              nowPlayingTitle: 'Midnight Drive',
              nowPlayingArtist: names.join('; '),
            ),
          ),
        );
        final block = _rect(
          tester,
          find
              .ancestor(
                of: _byType('_TrackInfo'),
                matching: find.byType(ClipRect),
              )
              .first,
        );
        final live = _rect(tester, find.text('LIVE'));
        expect(live.bottom, lessThanOrEqualTo(block.bottom));
        final first = _rect(tester, find.text(names.first));
        for (final (i, name) in names.indexed) {
          final finder = find.text('${i > 0 ? ', ' : ''}$name');
          expect(_rect(tester, finder).center.dy, closeTo(first.center.dy, .1));
          expect(finder.hitTestable(), findsOneWidget);
          final text = tester.widget<Text>(finder);
          expect(text.maxLines, 1);
          expect(text.overflow, TextOverflow.ellipsis);
          final gesture = tester.widget<GestureDetector>(
            find
                .ancestor(of: finder, matching: find.byType(GestureDetector))
                .first,
          );
          expect(gesture.onTap, isNotNull);
        }
        expect(find.byType(Scrollable), findsNothing);
        expect(tester.takeException(), isNull);
      },
      skip: !sqliteAvailable,
    );
  }

  testWidgets('200 percent text keeps the controls pinned and visible', (
    tester,
  ) async {
    const size = Size(360, 640);
    await _pump(tester, size, bottomInset: 48, textScale: 2);
    expect(tester.takeException(), isNull);
    final l = _model(tester, size, 2);
    expect(l.scalesUpper, isFalse);
    expect(l.showInfo, isFalse);
    final settings = _rect(tester, find.byTooltip('Settings'));
    expect(settings.bottom, lessThanOrEqualTo(size.height - 48));
    expect(_rect(tester, find.byType(CoverArtImage)).width, l.artSize);
  }, skip: !sqliteAvailable);

  testWidgets('when nothing fits the cover and title scale, never scroll', (
    tester,
  ) async {
    const size = Size(360, 480);
    await _pump(tester, size, bottomInset: 48, textScale: 2);
    expect(tester.takeException(), isNull);
    final l = _model(tester, size, 2);
    expect(l.scalesUpper, isTrue);
    final body = _rect(tester, _byType('_NowPlayingBody'));
    // The controls keep their place above the inset ...
    final actions = _rect(tester, _byType('_ActionRow'));
    expect(actions.bottom, closeTo(body.bottom - l.bottom, 1));
    // ... and the cover and title shrink into the room above them.
    expect(find.byType(Scrollable), findsNothing);
    final cover = _rect(tester, find.byType(CoverArtImage));
    expect(cover.width, lessThan(l.artSize));
    expect(_rect(tester, _byType('_TrackInfo')).bottom, lessThan(actions.top));
    expect(cover.top, greaterThanOrEqualTo(body.top));
  }, skip: !sqliteAvailable);

  group('Now Playing never scrolls and keeps its height in any script', () {
    const scripts = <(String, MediaItem)>[
      ('latin', _item),
      ('arabic', _arabic),
      ('japanese', _japanese),
    ];
    // Lines far taller than Material's, as Arabic and CJK fallback fonts are.
    const tallLines = TextTheme(
      titleLarge: TextStyle(height: 2.2),
      bodyLarge: TextStyle(height: 2.2),
      bodyMedium: TextStyle(height: 2.2),
    );
    // The first (plain Latin) case of each phone and scale records the height
    // the others must keep; the loops below run it first.
    final latinHeights = <String, double>{};
    for (final (name, size) in _phones.take(3)) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final (script, item) in scripts) {
          for (final tall in [false, true]) {
            testWidgets(
              '$name at ${scale}x $script${tall ? ' with tall lines' : ''}',
              (tester) async {
                await _pump(
                  tester,
                  size,
                  textScale: scale,
                  item: item,
                  textTheme: tall ? tallLines : null,
                );
                expect(tester.takeException(), isNull);
                // No scroll view anywhere in the screen: the sheet's
                // swipe-down drag has nothing to compete with.
                expect(find.byType(Scrollable), findsNothing);
                // The Latin height, whatever the script, and within the budget.
                final height = _size(tester, '_TrackInfo').height;
                expect(
                  height,
                  lessThanOrEqualTo(_model(tester, size, scale).titleBlock),
                );
                expect(
                  height,
                  closeTo(
                    latinHeights.putIfAbsent('$name $scale', () => height),
                    0.01,
                  ),
                );
              },
              skip: !sqliteAvailable,
            );
          }
        }
      }
    }

    for (final (name, item, size, scale, target)
        in <(String, MediaItem, Size, double, Finder Function())>[
          (
            'Arabic cover',
            _arabic,
            const Size(390, 844),
            1,
            () => find.byType(CoverArtImage),
          ),
          (
            'Japanese title at 200 percent text',
            _japanese,
            const Size(360, 640),
            2,
            () => _byType('_TrackInfo'),
          ),
        ]) {
      testWidgets('a vertical drag on the $name collapses the sheet', (
        tester,
      ) async {
        var collapsed = 0;
        await _pump(
          tester,
          size,
          textScale: scale,
          item: item,
          onCollapse: () => collapsed++,
        );
        await tester.fling(target(), const Offset(0, 300), 1500);
        await tester.pumpAndSettle();
        expect(collapsed, greaterThan(0));
      }, skip: !sqliteAvailable);
    }

    testWidgets('radio keeps one height too', (tester) async {
      const size = Size(390, 844);
      await _pump(
        tester,
        size,
        playback: _radio.copyWith(
          radioStation: const RadioStationMetadata(
            stationId: 'radio-1',
            stationName: 'إذاعة القاهرة',
            streamUrl: 'https://example.com/radio',
            nowPlayingTitle: '夜に駆ける',
            nowPlayingArtist: 'أم كلثوم',
          ),
        ),
        textTheme: tallLines,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsNothing);
      expect(
        _size(tester, '_TrackInfo').height,
        closeTo(_model(tester, size, 1, radio: true).titleBlock, 1),
      );
    }, skip: !sqliteAvailable);
  });

  group('goldens', () {
    for (final (name, size) in _phones) {
      testWidgets('phone $name', (tester) async {
        await _pump(tester, size);
        await expectLater(
          find.byType(NowPlayingScreen),
          matchesGoldenFile('goldens/now_playing_phone_$name.png'),
        );
      }, skip: !sqliteAvailable);
    }

    testWidgets('phone 360x640 with three-button navigation', (tester) async {
      await _pump(tester, const Size(360, 640), bottomInset: 48);
      await expectLater(
        find.byType(NowPlayingScreen),
        matchesGoldenFile('goldens/now_playing_phone_360x640_three_button.png'),
      );
    }, skip: !sqliteAvailable);

    testWidgets('phone 390x844 at 200 percent text', (tester) async {
      await _pump(tester, const Size(390, 844), textScale: 2);
      await expectLater(
        find.byType(NowPlayingScreen),
        matchesGoldenFile(
          'goldens/now_playing_phone_390x844_text_scale_200.png',
        ),
      );
    }, skip: !sqliteAvailable);

    testWidgets('phone 390x844 radio', (tester) async {
      await _pump(tester, const Size(390, 844), playback: _radio);
      await expectLater(
        find.byType(NowPlayingScreen),
        matchesGoldenFile('goldens/now_playing_phone_390x844_radio.png'),
      );
    }, skip: !sqliteAvailable);
  });
}
