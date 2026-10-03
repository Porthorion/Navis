import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';

void main() {
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
}
