import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/library/data/local_track_matcher.dart';

TrackMatchCandidate _candidate(
  String id,
  String title, {
  String artist = 'ONE OK ROCK',
  String? album,
  int? duration,
}) => TrackMatchCandidate.fromSong(
  Song(id: id, title: title, artist: artist, album: album, duration: duration),
);

String? _match(TrackMatchQuery query, List<TrackMatchCandidate> candidates) =>
    pickBestTrackMatch(track: query, candidates: candidates).song?.id;

void main() {
  group('non-Latin titles', () {
    test('a Japanese title matches only the same Japanese title', () {
      final candidates = <TrackMatchCandidate>[
        _candidate('other', '完全感覚Dreamer', artist: 'ワンオクロック'),
        _candidate('target', '残響リファレンス', artist: 'ワンオクロック'),
      ];
      expect(
        _match(
          const TrackMatchQuery(title: '「残響リファレンス」', artist: 'ワンオクロック'),
          candidates,
        ),
        'target',
      );
    });

    test('an unrelated Japanese title does not match', () {
      expect(
        _match(
          const TrackMatchQuery(title: '花', artist: '嵐'),
          <TrackMatchCandidate>[
            _candidate('other', '残響リファレンス', artist: 'ワンオクロック'),
          ],
        ),
        isNull,
      );
    });

    test('a full-width artist matches its half-width spelling', () {
      expect(
        _match(
          const TrackMatchQuery(
            title: 'Wherever you are',
            artist: 'ＯＮＥ　ＯＫ　ＲＯＣＫ',
          ),
          <TrackMatchCandidate>[_candidate('target', 'Wherever You Are')],
        ),
        'target',
      );
    });

    test('a Korean title matches without its English subtitle', () {
      final candidates = <TrackMatchCandidate>[
        _candidate('kr', '봄날', artist: '방탄소년단'),
      ];
      expect(
        _match(
          const TrackMatchQuery(title: '봄날 (Spring Day)', artist: '방탄소년단'),
          candidates,
        ),
        'kr',
      );
    });
  });

  group('language versions', () {
    final plain = _candidate('plain', 'Wonder', album: 'Single');
    final japanese = _candidate(
      'jp',
      'Wonder (Japanese Version)',
      album: 'Single',
    );
    final english = _candidate(
      'en',
      'Wonder (English Version)',
      album: 'Single',
    );

    test('an expected Japanese version prefers the Japanese candidate', () {
      const query = TrackMatchQuery(
        title: 'Wonder (Japanese Version)',
        artist: 'ONE OK ROCK',
      );
      expect(_match(query, <TrackMatchCandidate>[plain, japanese]), 'jp');
      expect(_match(query, <TrackMatchCandidate>[english, japanese]), 'jp');
      expect(_match(query, <TrackMatchCandidate>[japanese, english]), 'jp');
    });

    test('an expected plain title prefers the plain candidate', () {
      const query = TrackMatchQuery(title: 'Wonder', artist: 'ONE OK ROCK');
      expect(_match(query, <TrackMatchCandidate>[japanese, plain]), 'plain');
      expect(_match(query, <TrackMatchCandidate>[plain, english]), 'plain');
    });

    test('an exact edition wins even when the other has the album and '
        'duration', () {
      const query = TrackMatchQuery(
        title: 'Wonder',
        artist: 'ONE OK ROCK',
        album: 'Luxury Disease',
        durationSeconds: 200,
      );
      final japaneseOnAlbum = _candidate(
        'jp',
        'Wonder (Japanese Version)',
        album: 'Luxury Disease',
        duration: 200,
      );
      final plainSingle = _candidate('plain', 'Wonder', album: 'Single');
      expect(
        _match(query, <TrackMatchCandidate>[japaneseOnAlbum, plainSingle]),
        'plain',
      );
    });

    test('a different version is still used when it is the only one', () {
      const query = TrackMatchQuery(title: 'Wonder', artist: 'ONE OK ROCK');
      expect(_match(query, <TrackMatchCandidate>[japanese]), 'jp');
    });
  });
}
