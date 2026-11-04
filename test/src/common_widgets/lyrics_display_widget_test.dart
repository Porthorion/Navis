import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';

void main() {
  for (final realLyrics in [false, true]) {
    testWidgets(
      'instrumental empty state yields to real lyrics: real=$realLyrics',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: LyricsDisplayWidget(
                lyrics: LyricsList(value: realLyrics ? 'real words' : null),
                instrumental: true,
                currentPosition: Duration.zero,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Instrumental'),
          realLyrics ? findsNothing : findsOneWidget,
        );
        if (realLyrics) {
          expect(find.textContaining('real words'), findsOneWidget);
        }
        expect(find.text('No Lyrics Available'), findsNothing);
      },
    );
  }

  LyricsList longLyrics() => LyricsList(
    structuredLyrics: [
      StructuredLyrics(
        synced: true,
        line: List.generate(
          70,
          (i) => LyricLine(start: i * 1000, value: 'Line $i'),
        ),
      ),
    ],
  );

  Future<void> showLyrics(WidgetTester tester, List<Duration> seeks) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsDisplayWidget(
            lyrics: longLyrics(),
            currentPosition: const Duration(seconds: 10),
            onSeek: seeks.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('wheel browsing postpones following from the final interaction', (
    tester,
  ) async {
    final seeks = <Duration>[];
    await showLyrics(tester, seeks);
    final at = tester.getCenter(find.byType(LyricsDisplayWidget));
    Future<void> wheel() async {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: at, scrollDelta: const Offset(0, 200)),
      );
      await tester.pump();
    }

    await wheel();
    expect(find.byIcon(Icons.my_location), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await wheel();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byIcon(Icons.my_location), findsOneWidget);
    expect(seeks, isEmpty);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.my_location), findsNothing);
    expect(seeks, isEmpty);
  });

  testWidgets('touch browsing pauses following; tapping a line seeks once', (
    tester,
  ) async {
    final seeks = <Duration>[];
    await showLyrics(tester, seeks);
    expect(seeks, isEmpty);
    await tester.tap(find.text('Line 10'));
    await tester.pump();
    expect(seeks, [const Duration(seconds: 10)]);
    seeks.clear();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(LyricsDisplayWidget)),
    );
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.byIcon(Icons.my_location), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(seeks, isEmpty);
    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.my_location), findsNothing);
  });

  testWidgets('trackpad following waits until the gesture ends', (
    tester,
  ) async {
    final seeks = <Duration>[];
    await showLyrics(tester, seeks);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(
      tester.getCenter(find.byType(LyricsDisplayWidget)),
    );
    await gesture.panZoomUpdate(
      tester.getCenter(find.byType(LyricsDisplayWidget)),
      pan: const Offset(0, -200),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.byIcon(Icons.my_location), findsOneWidget);
    await gesture.panZoomEnd();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byIcon(Icons.my_location), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.my_location), findsNothing);
    expect(seeks, isEmpty);
  });

  const lyrics = LyricsList(
    structuredLyrics: <StructuredLyrics>[
      StructuredLyrics(
        synced: true,
        line: <LyricLine>[
          LyricLine(start: 1000, value: 'one'),
          LyricLine(start: 4000, value: 'two'),
          LyricLine(start: 9000, value: 'three'),
        ],
      ),
    ],
  );

  Duration at(int ms) =>
      lyricsActiveLinePosition(lyrics, Duration(milliseconds: ms));

  test('maps a position to the start of its active line', () {
    expect(at(0), const Duration(milliseconds: -1));
    expect(at(999), const Duration(milliseconds: -1));
    expect(at(1000), const Duration(seconds: 1));
    expect(at(3999), const Duration(seconds: 1));
    expect(at(4000), const Duration(seconds: 4));
    expect(at(120000), const Duration(seconds: 9));
  });

  test(
    'positions within one line are equal, so the widget does not rebuild',
    () {
      expect(at(4100), at(8900));
    },
  );

  test('unsynced or missing lyrics map to a constant', () {
    expect(
      lyricsActiveLinePosition(null, const Duration(seconds: 5)),
      const Duration(milliseconds: -1),
    );
    expect(
      lyricsActiveLinePosition(
        const LyricsList(value: 'plain text'),
        const Duration(seconds: 5),
      ),
      const Duration(milliseconds: -1),
    );
  });

  testWidgets('server plain lyrics (structured lines without start) show', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LyricsDisplayWidget(
            lyrics: LyricsList(
              structuredLyrics: [
                StructuredLyrics(
                  synced: false,
                  line: [
                    LyricLine(value: 'First plain'),
                    LyricLine(value: ''),
                  ],
                ),
              ],
            ),
            currentPosition: Duration.zero,
            onSeek: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('First plain'), findsOneWidget);
    expect(find.text('No Lyrics Available'), findsNothing);
  });

  group('follow position at the start of a song', () {
    LyricsList lyricsWith({String firstLine = 'Line 0'}) => LyricsList(
      structuredLyrics: [
        StructuredLyrics(
          synced: true,
          line: List.generate(
            40,
            (i) => LyricLine(
              start: i * 3000,
              value: i == 0 ? firstLine : 'Line $i',
            ),
          ),
        ),
      ],
    );

    Future<double> settledActiveY(
      WidgetTester tester,
      LyricsList lyrics,
      int line,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricsDisplayWidget(
              lyrics: lyrics,
              currentPosition: Duration(milliseconds: line * 3000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getTopLeft(find.text('Line $line')).dy;
    }

    // Heights agree within 5 px: the first jump and the animated follow differ
    // by about 3 px (active font size), versus 40-140 px without the fix.
    //
    // The active line must rest at one height from the first line on. When the
    // list could not scroll far enough for the first lines (top padding smaller
    // than the follow alignment), the active line walked down the screen for
    // lines 0-2 and then slid back up once scrolling became possible.
    testWidgets('active line rests at the same height from line 0 on', (
      tester,
    ) async {
      final lyrics = lyricsWith();
      final reference = await settledActiveY(tester, lyrics, 10);
      for (final line in [0, 1, 2, 3, 4]) {
        expect(
          await settledActiveY(tester, lyrics, line),
          closeTo(reference, 5),
          reason: 'line $line',
        );
      }
    });

    testWidgets('seeking back to the start settles at the same height', (
      tester,
    ) async {
      final lyrics = lyricsWith();
      final reference = await settledActiveY(tester, lyrics, 10);
      Widget app(int ms) => MaterialApp(
        home: Scaffold(
          body: LyricsDisplayWidget(
            lyrics: lyrics,
            currentPosition: Duration(milliseconds: ms),
          ),
        ),
      );
      await tester.pumpWidget(app(0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Line 0')).dy, closeTo(reference, 5));
    });

    testWidgets('a blank first line does not change the resting height', (
      tester,
    ) async {
      final reference = await settledActiveY(tester, lyricsWith(), 10);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricsDisplayWidget(
              lyrics: lyricsWith(firstLine: ''),
              currentPosition: const Duration(seconds: 3),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Line 1')).dy, closeTo(reference, 5));
    });

    testWidgets('following never moves away from the active line', (
      tester,
    ) async {
      final lyrics = lyricsWith();
      Widget app(int ms) => MaterialApp(
        home: Scaffold(
          body: LyricsDisplayWidget(
            lyrics: lyrics,
            currentPosition: Duration(milliseconds: ms),
          ),
        ),
      );
      await tester.pumpWidget(app(0));
      await tester.pumpAndSettle();
      final rest = tester.getTopLeft(find.text('Line 0')).dy;
      for (var line = 1; line <= 6; line++) {
        await tester.pumpWidget(app(line * 3000));
        var previous = double.infinity;
        for (var frame = 0; frame < 25; frame++) {
          final y = tester.getTopLeft(find.text('Line $line')).dy;
          // Only ever glides up toward the resting height, never past it.
          expect(y, lessThanOrEqualTo(previous + 0.5), reason: 'line $line');
          expect(y, greaterThanOrEqualTo(rest - 5), reason: 'line $line');
          previous = y;
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(previous, closeTo(rest, 5), reason: 'line $line');
      }
    });
  });
}
