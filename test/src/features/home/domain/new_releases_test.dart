import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';

ArtistsTableData _artist(String id) => ArtistsTableData(
  isProvisional: false,
  isExternal: false,
  id: id,
  name: id.toUpperCase(),
);

AlbumsTableData _libraryAlbum(String id, String name) => AlbumsTableData(
  isProvisional: false,
  isExternal: false,
  id: id,
  name: name,
  songsHydrated: true,
  artists: const [],
);

DeezerAlbum _release(int id, String date, {String? title, String? type}) =>
    DeezerAlbum(
      id: id,
      title: title ?? 'Release $id',
      releaseDate: date,
      recordType: type ?? 'single',
    );

ArtistReleases _releases(
  String artist,
  List<DeezerAlbum> releases, {
  List<AlbumsTableData> library = const [],
}) => (artist: _artist(artist), releases: releases, libraryAlbums: library);

void main() {
  final today = DateTime(2026, 10, 5, 18, 30);

  group('parseDeezerReleaseDate', () {
    test('reads the release day', () {
      expect(parseDeezerReleaseDate('2026-10-02'), DateTime(2026, 10, 2));
    });

    test('rejects missing and malformed dates', () {
      for (final value in <String?>[
        null,
        '',
        '0000-00-00',
        '2026-13-01',
        '2026-02-31',
        '2026-10',
        'soon',
      ]) {
        expect(parseDeezerReleaseDate(value), isNull, reason: '$value');
      }
    });
  });

  group('selectNewReleases', () {
    test('keeps the last 30 days, today included, never the future', () {
      final selected = selectNewReleases(<ArtistReleases>[
        _releases('a', <DeezerAlbum>[
          _release(1, '2026-10-06'), // announced for tomorrow
          _release(2, '2026-10-05'), // today
          _release(3, '2026-09-05'), // 30 days ago
          _release(4, '2026-09-04'), // 31 days ago
          _release(5, ''), // no date
        ]),
      ], today: today);
      expect(selected.map((r) => r.album.id), <int>[2, 3]);
    });

    test('newest first, the higher-ranked artist first on a tie', () {
      final selected = selectNewReleases(<ArtistReleases>[
        _releases('top', <DeezerAlbum>[
          _release(1, '2026-09-20'),
          _release(2, '2026-10-01'),
        ]),
        _releases('second', <DeezerAlbum>[
          _release(3, '2026-10-01'),
          _release(4, '2026-10-03'),
        ]),
      ], today: today);
      expect(selected.map((r) => r.album.id), <int>[4, 2, 3, 1]);
      expect(selected.first.artistName, 'SECOND');
      expect(selected.first.releasedOn, DateTime(2026, 10, 3));
    });

    test('caps the list', () {
      final selected = selectNewReleases(<ArtistReleases>[
        _releases('a', <DeezerAlbum>[
          for (var day = 1; day <= 20; day++)
            _release(day, '2026-09-${day.toString().padLeft(2, '0')}'),
        ]),
      ], today: today);
      expect(selected, hasLength(kNewReleasesLimit));
      expect(selected.first.album.id, 20);
    });

    test('shows a release once, and one edition once per artist', () {
      final duet = _release(9, '2026-10-01', title: 'Duet');
      final selected = selectNewReleases(<ArtistReleases>[
        _releases('a', <DeezerAlbum>[
          duet,
          // Deezer's clean and explicit releases of one single.
          _release(10, '2026-10-02', title: 'Signal'),
          _release(11, '2026-10-02', title: 'Signal'),
          _release(12, '2026-10-02', title: 'Signal (Japanese Version)'),
        ]),
        _releases('b', <DeezerAlbum>[duet]),
      ], today: today);
      expect(selected.map((r) => r.album.id), <int>[10, 12, 9]);
      expect(selected.last.artistId, 'a');
    });

    test('links a release the library has', () {
      final selected = selectNewReleases(<ArtistReleases>[
        _releases(
          'a',
          <DeezerAlbum>[
            _release(1, '2026-10-01', title: 'Wonder (Japanese Version)'),
            _release(2, '2026-10-02', title: 'Remote'),
            _release(3, '2026-10-03', title: 'Ambitions'),
          ],
          library: <AlbumsTableData>[
            _libraryAlbum('lib-wonder', 'Wonder'),
            _libraryAlbum('ext-deezer-album-2', 'Remote (Deluxe)'),
            _libraryAlbum('lib-ambitions', 'Ambitions (Remastered)'),
          ],
        ),
      ], today: today);
      expect(
        <int, String?>{
          for (final release in selected)
            release.album.id: release.libraryAlbumId,
        },
        <int, String?>{
          3: 'lib-ambitions',
          2: 'ext-deezer-album-2',
          // The Japanese edition is not the library's "Wonder".
          1: null,
        },
      );
    });
  });
}
