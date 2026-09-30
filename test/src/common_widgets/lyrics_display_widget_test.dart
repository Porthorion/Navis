import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';

void main() {
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
