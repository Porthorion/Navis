import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/utils/catalog_source.dart';

void main() {
  test('API models preserve true false and missing external values', () {
    expect(
      Artist.fromJson(const <String, dynamic>{
        'id': 'artist-1',
        'name': 'Artist',
        'isExternal': true,
      }).isExternal,
      isTrue,
    );
    expect(
      Album.fromJson(const <String, dynamic>{
        'id': 'album-1',
        'name': 'Album',
        'isExternal': false,
      }).isExternal,
      isFalse,
    );
    expect(
      Song.fromJson(const <String, dynamic>{
        'id': 'song-1',
        'title': 'Song',
      }).isExternal,
      isNull,
    );
  });

  test('explicit values take precedence over ID fallback', () {
    expect(
      classifyCatalogSource(id: 'ext-imported', apiIsExternal: false),
      CatalogSource.onServer,
    );
    expect(
      classifyCatalogSource(id: 'ordinary-id', apiIsExternal: true),
      CatalogSource.external,
    );
  });

  test('only observed external ID families are fallback-classified', () {
    for (final id in <String>[
      'ext-deezer-song-1',
      'remote-provider-1',
      'pl-deezer-album-1',
    ]) {
      expect(classifyCatalogSource(id: id), CatalogSource.external);
    }
    for (final id in <String>[
      'external-looking',
      'deezer-album-1',
      'cover-ext-deezer-1',
      'server-song-1',
    ]) {
      expect(classifyCatalogSource(id: id), CatalogSource.onServer);
    }
  });
}
