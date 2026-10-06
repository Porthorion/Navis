import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
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
  test('single-character artist fallback requires equality', () async {
    final snapshot = await LocalTrackMatchSnapshot.fromSongsAsync([
      SongsTableData(
        id: 'x',
        title: 'Song',
        artistName: 'X',
        isProvisional: false,
        isExternal: false,
      ),
      SongsTableData(
        id: 'xx',
        title: 'Other',
        artistName: 'XX',
        isProvisional: false,
        isExternal: false,
      ),
      SongsTableData(
        id: 'arashi',
        title: '花',
        artistName: '嵐',
        isProvisional: false,
        isExternal: false,
      ),
      SongsTableData(
        id: 'other',
        title: 'Other',
        artistName: '嵐山',
        isProvisional: false,
        isExternal: false,
      ),
    ]);
    expect(
      snapshot
          .candidatesFor(const TrackMatchQuery(title: 'Unknown', artist: 'X'))
          .map((c) => c.song.id),
      ['x'],
    );
    expect(
      snapshot
          .candidatesFor(const TrackMatchQuery(title: 'Unknown', artist: '嵐'))
          .map((c) => c.song.id),
      ['arashi'],
    );
  });

  test('edition title is computed once per candidate', () {
    final candidate = _candidate('jp', 'Wonder (Japanese Version)');
    expect(identical(candidate.editionTitle, candidate.editionTitle), isTrue);
  });

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

    test('an exact edition wins when its album evidence is as good', () {
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
      final plainOnAlbum = _candidate(
        'plain',
        'Wonder',
        album: 'Luxury Disease',
      );
      expect(
        _match(query, <TrackMatchCandidate>[japaneseOnAlbum, plainOnAlbum]),
        'plain',
      );
    });

    test('another edition with the expected album keeps its better score', () {
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
        _match(query, <TrackMatchCandidate>[plainSingle, japaneseOnAlbum]),
        'jp',
      );
    });

    test('another edition with an exact artist beats a looser artist', () {
      const query = TrackMatchQuery(title: 'Wonder', artist: 'ONE OK ROCK');
      expect(
        _match(query, <TrackMatchCandidate>[
          _candidate('plain', 'Wonder', artist: 'ONE OK ROCK & Friends'),
          japanese,
        ]),
        'jp',
      );
    });

    test('preferring the edition never turns a match ambiguous', () {
      const query = TrackMatchQuery(
        title: 'Wonder',
        artist: 'ONE OK ROCK',
        durationSeconds: 200,
      );
      expect(
        _match(query, <TrackMatchCandidate>[
          _candidate('jp', 'Wonder (Japanese Version)', duration: 200),
          _candidate('plain-a', 'Wonder', album: 'A'),
          _candidate('plain-b', 'Wonder', artist: 'ONEOKROCK', album: 'B'),
        ]),
        'jp',
      );
    });

    test('a remaster on the expected album beats a live album copy', () {
      const query = TrackMatchQuery(
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
        album: 'A Night at the Opera',
        durationSeconds: 355,
      );
      expect(
        _match(query, <TrackMatchCandidate>[
          _candidate(
            'live',
            'Bohemian Rhapsody',
            artist: 'Queen',
            album: "Live at Wembley '86",
            duration: 420,
          ),
          _candidate(
            'remaster',
            'Bohemian Rhapsody (Remastered 2011)',
            artist: 'Queen',
            album: 'A Night at the Opera',
            duration: 355,
          ),
        ]),
        'remaster',
      );
    });

    test('a different version is still used when it is the only one', () {
      const query = TrackMatchQuery(title: 'Wonder', artist: 'ONE OK ROCK');
      expect(_match(query, <TrackMatchCandidate>[japanese]), 'jp');
    });
  });
}
