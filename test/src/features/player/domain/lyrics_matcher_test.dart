import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/lyrics_matcher.dart';

void main() {
  const expected = LrclibMatchCandidate(
    artist: 'ワンオクロック',
    title: '残響リファレンス',
    durationSeconds: 240,
  );

  test('an LRCLIB result with the same Japanese title and artist passes', () {
    final score = scoreCandidate(
      expected: expected,
      candidate: const LrclibMatchCandidate(
        artist: 'ワンオクロック',
        title: '「残響リファレンス」',
        durationSeconds: 241,
      ),
    );
    expect(score.passes(), isTrue);
  });

  test('a different Japanese title by a different artist scores nothing for '
      'text', () {
    // Both used to normalize to an empty key, so any two Japanese titles
    // "matched".
    final score = scoreCandidate(
      expected: expected,
      candidate: const LrclibMatchCandidate(
        artist: '嵐',
        title: '花',
        durationSeconds: 240,
      ),
    );
    expect(score.value, closeTo(0.2, 1e-9));
    expect(score.passes(), isFalse);
  });

  test('a different language version scores the same but is flagged', () {
    LrclibMatchScore score(String title) => scoreCandidate(
      expected: const LrclibMatchCandidate(
        artist: 'ONE OK ROCK',
        title: 'Wonder (Japanese Version)',
      ),
      candidate: LrclibMatchCandidate(artist: 'ONE OK ROCK', title: title),
    );
    expect(score('Wonder (Japanese Version)').sameEdition, isTrue);
    expect(score('Wonder').sameEdition, isFalse);
    expect(score('Wonder').value, score('Wonder (Japanese Version)').value);
  });
}
