import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';

void main() {
  group('Freezed model serialization', () {
    for (final readOnly in <bool?>[true, false, null]) {
      test('playlist parses and round-trips readonly=$readOnly', () {
        final playlist = Playlist.fromJson(<String, dynamic>{
          'id': 'playlist',
          'name': 'Playlist',
          'readonly': ?readOnly,
        });
        expect(playlist.readOnly, readOnly);
        expect(playlist.toJson()['readonly'], readOnly);
        expect(Playlist.fromJson(playlist.toJson()), playlist);
      });
    }

    test('serializes and deserializes Song', () {
      const song = Song(
        id: 's1',
        title: 'Track 1',
        album: 'Album',
        artist: 'Artist',
        bitRate: 320,
      );

      final json = song.toJson();
      final decoded = Song.fromJson(json);

      expect(decoded, song);
    });

    test('serializes SubsonicResponse generic payload', () {
      const payload = SearchResult3();
      const response = SubsonicResponse<SearchResult3>(
        status: 'ok',
        version: '1.16.1',
        data: payload,
      );

      final json = response.toJson((value) => value.toJson());
      final decoded = SubsonicResponse<SearchResult3>.fromJson(
        json,
        (value) => SearchResult3.fromJson(value! as Map<String, dynamic>),
      );

      expect(decoded.status, 'ok');
      expect(decoded.data, payload);
    });

    test('deserializes structured lyrics', () {
      final json = <String, dynamic>{
        'structuredLyrics': <Map<String, dynamic>>[
          <String, dynamic>{
            'lang': 'en',
            'synced': true,
            'line': <Map<String, dynamic>>[
              <String, dynamic>{'start': 0, 'value': 'line'},
            ],
          },
        ],
      };

      final lyrics = LyricsList.fromJson(json);
      expect(lyrics.structuredLyrics, hasLength(1));
      expect(lyrics.structuredLyrics.first.line.first.value, 'line');
    });

    group('Song genres', () {
      Song parse(Map<String, dynamic> extra) =>
          Song.fromJson(<String, dynamic>{'id': 's', 'title': 'T', ...extra});

      test('the OpenSubsonic genres list wins over the legacy genre', () {
        final song = parse(<String, dynamic>{
          'genre': 'Pop',
          'genres': <Object>[
            <String, Object>{'name': 'Rock'},
            <String, Object>{'name': 'Jazz'},
          ],
        });
        expect(song.genres, <String>['Rock', 'Jazz']);
      });

      test('falls back to the legacy genre as one tag when the list is '
          'missing or empty', () {
        expect(parse(<String, dynamic>{'genre': 'Rock'}).genres, ['Rock']);
        expect(
          parse(<String, dynamic>{'genre': 'Rock', 'genres': const <Object>[]})
              .genres,
          ['Rock'],
        );
        expect(parse(const <String, dynamic>{}).genres, isEmpty);
      });

      test('never splits a tag on punctuation', () {
        expect(parse(<String, dynamic>{'genre': 'Rock & Roll'}).genres, [
          'Rock & Roll',
        ]);
        expect(
          parse(<String, dynamic>{
            'genres': <Object>[
              <String, Object>{'name': 'Drum/Bass'},
              <String, Object>{'name': 'Rock; Pop'},
            ],
          }).genres,
          ['Drum/Bass', 'Rock; Pop'],
        );
      });

      test('drops empty names and dedupes by merge key, keeping the first', () {
        final song = parse(<String, dynamic>{
          'genres': <Object>[
            <String, Object>{'name': ' Hip Hop '},
            <String, Object>{'name': ''},
            <String, Object>{'name': '   '},
            <String, Object>{'name': '-'},
            <String, Object>{'name': 'hip-hop'},
            <String, Object>{'name': 'Rock'},
          ],
        });
        expect(song.genres, <String>['Hip Hop', 'Rock']);
      });

      test('round-trips through toJson', () {
        final song = parse(<String, dynamic>{
          'genres': <Object>[
            <String, Object>{'name': 'Rock'},
            <String, Object>{'name': 'Jazz'},
          ],
        });
        expect(Song.fromJson(song.toJson()).genres, song.genres);
      });
    });

    test('deserializes ScanStatus including a missing lastScan', () {
      final complete = ScanStatus.fromJson(<String, dynamic>{
        'scanning': false,
        'count': 56166,
        'lastScan': '2026-09-20T07:13:38.721Z',
      });
      expect(complete.scanning, isFalse);
      expect(complete.count, 56166);
      expect(complete.lastScan, isNotNull);

      final minimal = ScanStatus.fromJson(<String, dynamic>{});
      expect(minimal.scanning, isFalse);
      expect(minimal.count, isNull);
      expect(minimal.lastScan, isNull);
    });

    test('albums carry no genre; theirs derives from their songs', () {
      const base = <String, dynamic>{'id': 'al-1', 'name': 'A', 'year': 2020};
      final tagged = Album.fromJson(<String, dynamic>{
        ...base,
        'genre': 'Rock',
      });
      final retagged = Album.fromJson(<String, dynamic>{
        ...base,
        'genre': 'Jazz',
      });
      expect(tagged, Album.fromJson(base));
      expect(retagged, tagged);
      expect(tagged.toJson(), isNot(contains('genre')));
    });

    test('round-trips album and artist MusicBrainz identifiers', () {
      const album = Album(
        id: 'al-1',
        name: 'Album',
        musicBrainzId: 'release-mbid',
      );
      final decodedAlbum = Album.fromJson(album.toJson());
      expect(decodedAlbum.musicBrainzId, 'release-mbid');
      expect(
        Album.fromJson(<String, dynamic>{'id': 'al-2', 'name': 'B'})
            .musicBrainzId,
        isNull,
      );

      const artist = Artist(
        id: 'ar-1',
        name: 'Artist',
        musicBrainzId: 'artist-mbid',
      );
      final decodedArtist = Artist.fromJson(artist.toJson());
      expect(decodedArtist.musicBrainzId, 'artist-mbid');
      expect(
        Artist.fromJson(<String, dynamic>{'id': 'ar-2', 'name': 'B'})
            .musicBrainzId,
        isNull,
      );
    });

    test('names decode HTML entities, ids do not', () {
      const raw = 'Come &amp; Get It (The Remixes)';
      const clean = 'Come & Get It (The Remixes)';
      final album = Album.fromJson(<String, dynamic>{
        'id': 'a&amp;1',
        'name': raw,
        'artist': 'Tom &amp; Jerry',
        'artists': <Object>[
          <String, Object>{'id': 'r&amp;1', 'name': 'Tom &amp; Jerry'},
        ],
      });
      expect(album.id, 'a&amp;1');
      expect(album.name, clean);
      expect(album.artist, 'Tom & Jerry');
      expect(album.artists.single.id, 'r&amp;1');
      expect(album.artists.single.name, 'Tom & Jerry');

      final artist = Artist.fromJson(<String, dynamic>{
        'id': 'ar&amp;1',
        'name': 'Tom &amp; Jerry',
      });
      expect(artist.id, 'ar&amp;1');
      expect(artist.name, 'Tom & Jerry');

      final song = Song.fromJson(<String, dynamic>{
        'id': 's&amp;1',
        'title': raw,
        'album': raw,
        'artist': 'Tom &amp; Jerry',
        'albumId': 'a&amp;1',
        'coverArt': 'al-&amp;1',
        'genres': <Object>[
          <String, Object>{'name': 'R&amp;B'},
        ],
      });
      expect(song.id, 's&amp;1');
      expect(song.albumId, 'a&amp;1');
      expect(song.coverArt, 'al-&amp;1');
      expect(song.title, clean);
      expect(song.album, clean);
      expect(song.artist, 'Tom & Jerry');
      expect(song.genres, <String>['R&B']);
      expect(
        Song.fromJson(<String, dynamic>{
          'id': 's',
          'title': 'T',
          'genre': 'R&amp;B',
        }).genres,
        <String>['R&B'],
      );
      expect(Song.fromJson(song.toJson()), song);
    });
  });
}
