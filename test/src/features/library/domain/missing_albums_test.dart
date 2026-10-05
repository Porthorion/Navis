import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/missing_albums.dart';

AlbumsTableData _library(String id, String name) => AlbumsTableData(
  isProvisional: false,
  isExternal: false,
  id: id,
  name: name,
  songsHydrated: true,
  artists: const [],
);

DeezerAlbum _deezer(
  int id,
  String title, {
  String type = 'album',
  String date = '2020-01-01',
}) => DeezerAlbum(id: id, title: title, recordType: type, releaseDate: date);

List<String> _titles(List<DeezerAlbum> albums) =>
    albums.map((album) => album.title).toList();

void main() {
  test('Japanese and English editions stay distinct', () {
    final missing = missingDeezerAlbums(
      deezerAlbums: [
        _deezer(1, 'Ambitions', date: '2017-01-13'),
        _deezer(2, 'Ambitions (Japanese Version)', date: '2017-01-11'),
        _deezer(3, 'Eye of the Storm (Japanese Version)', date: '2019-02-15'),
      ],
      libraryAlbums: [
        _library('al-1', 'Ambitions'),
        _library('al-2', 'Eye of the Storm'),
      ],
    );

    expect(_titles(missing), [
      'Eye of the Storm (Japanese Version)',
      'Ambitions (Japanese Version)',
    ]);
  });

  test('a library Japanese edition hides only the Japanese edition', () {
    final missing = missingDeezerAlbums(
      deezerAlbums: [
        _deezer(1, 'Ambitions'),
        _deezer(2, 'Ambitions (Japanese Version)'),
      ],
      libraryAlbums: [_library('al-1', 'Ambitions (Japanese Version)')],
    );

    expect(_titles(missing), ['Ambitions']);
  });

  test('remaster and deluxe packaging match the library album', () {
    final missing = missingDeezerAlbums(
      deezerAlbums: [
        _deezer(1, 'Nevermind (Remastered)'),
        _deezer(2, 'In Utero (Deluxe Edition)'),
        _deezer(3, 'Bleach'),
      ],
      libraryAlbums: [
        _library('al-1', 'Nevermind'),
        _library('al-2', 'In Utero [20th Anniversary Edition]'),
      ],
    );

    expect(_titles(missing), ['Bleach']);
  });

  test('a library album imported from Deezer matches by id', () {
    final missing = missingDeezerAlbums(
      deezerAlbums: [_deezer(302127, 'Renamed On Deezer'), _deezer(5, 'Other')],
      libraryAlbums: [_library('ext-deezer-album-302127', 'Server Title')],
    );

    expect(_titles(missing), ['Other']);
    expect(deezerIdFromLibraryAlbumId('ext-deezer-album-302127'), 302127);
    expect(deezerIdFromLibraryAlbumId('album-302127'), isNull);
  });

  test('only albums and EPs are listed', () {
    final missing = missingDeezerAlbums(
      deezerAlbums: [
        _deezer(1, 'LP'),
        _deezer(2, 'Extended Play', type: 'ep'),
        _deezer(3, 'Single', type: 'single'),
        _deezer(4, 'Best Of', type: 'compile'),
        const DeezerAlbum(id: 5, title: 'No type'),
      ],
      libraryAlbums: const [],
    );

    expect(_titles(missing), ['LP', 'Extended Play']);
  });

  test("Deezer's duplicate releases of one edition appear once", () {
    final missing = missingDeezerAlbums(
      deezerAlbums: [
        _deezer(1, 'Luxury Disease', date: '2022-09-09'),
        _deezer(2, 'Luxury Disease', date: '2022-09-09'),
        _deezer(3, 'Luxury Disease (Japanese Version)', date: '2022-09-07'),
      ],
      libraryAlbums: const [],
    );

    expect(missing.map((album) => album.id), [1, 3]);
  });

  test('newest first', () {
    final missing = missingDeezerAlbums(
      deezerAlbums: [
        _deezer(1, 'Old', date: '2010-05-01'),
        _deezer(2, 'New', date: '2024-05-01'),
        _deezer(3, 'Middle', date: '2018-05-01'),
      ],
      libraryAlbums: const [],
    );

    expect(_titles(missing), ['New', 'Middle', 'Old']);
  });
}
