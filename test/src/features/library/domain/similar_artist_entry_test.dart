import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/similar_artist_entry.dart';

ArtistsTableData _library(String id, String name, {String? coverArt}) =>
    ArtistsTableData(
      isProvisional: false,
      isExternal: false,
      id: id,
      name: name,
      coverArt: coverArt,
    );

void main() {
  test('library artists come first, each group in Deezer order', () {
    final entries = fansAlsoLikeEntries(
      related: const [
        DeezerArtist(id: 1, name: 'Coldrain', pictureXl: 'https://x/1.jpg'),
        DeezerArtist(id: 2, name: 'MY FIRST STORY'),
        DeezerArtist(id: 3, name: 'Crossfaith', pictureBig: 'https://x/3.jpg'),
        DeezerArtist(id: 4, name: 'SiM'),
      ],
      libraryByName: {
        'my first story': _library('lib-mfs', 'MY FIRST STORY', coverArt: 'c'),
        'sim': _library('lib-sim', 'SiM'),
      },
      currentArtistId: 'lib-oor',
      currentArtistName: 'ONE OK ROCK',
    );

    expect(entries.map((entry) => entry.name), [
      'MY FIRST STORY',
      'SiM',
      'Coldrain',
      'Crossfaith',
    ]);
    expect(entries.first.libraryArtistId, 'lib-mfs');
    expect(entries.first.coverArt, 'c');
    expect(entries.first.libraryArtistId, isNotNull);
    expect(entries[2].libraryArtistId, isNull);
    expect(entries[2].imageUrl, 'https://x/1.jpg');
    expect(entries[3].imageUrl, 'https://x/3.jpg');
  });

  test('the page artist and repeated names are left out', () {
    final entries = fansAlsoLikeEntries(
      related: const [
        DeezerArtist(id: 1, name: 'One Ok Rock'),
        DeezerArtist(id: 2, name: 'Coldrain'),
        DeezerArtist(id: 3, name: 'coldrain'),
        DeezerArtist(id: 4, name: 'Alias'),
      ],
      libraryByName: {'alias': _library('lib-oor', 'Alias')},
      currentArtistId: 'lib-oor',
      currentArtistName: 'ONE OK ROCK',
    );

    expect(entries.map((entry) => entry.name), ['Coldrain']);
  });
}
