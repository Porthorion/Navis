import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Helper to build a Song with minimal required fields.
  // ---------------------------------------------------------------------------
  Song _song({
    String id = '1',
    required String title,
    String? artist,
    String? album,
  }) =>
      Song(
        id: id,
        title: title,
        artist: artist,
        album: album,
      );

  LastFmArtistTopTrack _lastFm({
    required String title,
    required String artist,
    int rank = 1,
  }) =>
      LastFmArtistTopTrack(rank: rank, title: title, artist: artist);

  // ---------------------------------------------------------------------------
  // Basic matching
  // ---------------------------------------------------------------------------

  test('selects exact match from candidates', () {
    final match = pickBestArtistTopTrackMatch(
      track: _lastFm(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [
        _song(id: '1', title: 'Bohemian Rhapsody', artist: 'Queen'),
        _song(id: '2', title: 'We Will Rock You', artist: 'Queen'),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, '1');
  });

  test('selects correct song when multiple artists have same title', () {
    final match = pickBestArtistTopTrackMatch(
      track: _lastFm(title: 'RUNAWAY', artist: 'Aurora'),
      candidates: [
        _song(id: '1', title: 'Runaway', artist: 'Kanye West'),
        _song(id: '2', title: 'Runaway', artist: 'Aurora'),
        _song(id: '3', title: 'Runaway', artist: 'Bon Jovi'),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, '2');
  });

  // ---------------------------------------------------------------------------
  // Threshold behaviour
  // ---------------------------------------------------------------------------

  test('returns null when no candidate exceeds minimum score', () {
    final match = pickBestArtistTopTrackMatch(
      track: _lastFm(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [
        _song(
          id: '1',
          title: 'Completely Different Song',
          artist: 'Unknown Band',
        ),
      ],
    );

    expect(match, isNull);
  });

  test('returns null for empty candidate list', () {
    final match = pickBestArtistTopTrackMatch(
      track: _lastFm(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [],
    );

    expect(match, isNull);
  });

  // ---------------------------------------------------------------------------
  // Live version penalty
  // ---------------------------------------------------------------------------

  test('prefers studio version over live recording', () {
    final match = pickBestArtistTopTrackMatch(
      track: _lastFm(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [
        _song(
          id: 'live',
          title: 'Bohemian Rhapsody (Live)',
          artist: 'Queen',
        ),
        _song(
          id: 'studio',
          title: 'Bohemian Rhapsody',
          artist: 'Queen',
        ),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, 'studio');
  });

  test('penalises songs on live albums', () {
    final match = pickBestArtistTopTrackMatch(
      track: _lastFm(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [
        _song(
          id: 'live-album',
          title: 'Bohemian Rhapsody',
          artist: 'Queen',
          album: 'Live at Wembley',
        ),
        _song(
          id: 'studio',
          title: 'Bohemian Rhapsody',
          artist: 'Queen',
          album: 'A Night at the Opera',
        ),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, 'studio');
  });

  // ---------------------------------------------------------------------------
  // Normalisation edge cases
  // ---------------------------------------------------------------------------

  test('matches despite parenthetical differences', () {
    final match = pickBestArtistTopTrackMatch(
      track: _lastFm(
        title: 'Blinding Lights',
        artist: 'The Weeknd',
      ),
      candidates: [
        _song(
          id: '1',
          title: 'Blinding Lights (Official Audio)',
          artist: 'The Weeknd',
        ),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, '1');
  });

  test('matches despite feat. in title', () {
    final match = pickBestArtistTopTrackMatch(
      track: _lastFm(title: 'Locked Out of Heaven', artist: 'Bruno Mars'),
      candidates: [
        _song(
          id: '1',
          title: 'Locked Out of Heaven (feat. Someone)',
          artist: 'Bruno Mars',
        ),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, '1');
  });

  test('matches case-insensitively', () {
    final match = pickBestArtistTopTrackMatch(
      track: _lastFm(title: 'bohemian rhapsody', artist: 'queen'),
      candidates: [
        _song(id: '1', title: 'Bohemian Rhapsody', artist: 'Queen'),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, '1');
  });

  test('matches when punctuation differs', () {
    final match = pickBestArtistTopTrackMatch(
      track: _lastFm(title: "Don't Stop Me Now", artist: 'Queen'),
      candidates: [
        _song(id: '1', title: 'Dont Stop Me Now', artist: 'Queen'),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, '1');
  });
}
