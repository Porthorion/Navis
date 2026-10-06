import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/library_artist_name_index.dart';
import 'package:navis/src/features/library/presentation/artist_deezer_providers.dart';

import '../../../../helpers/test_database.dart';

ArtistsTableData _artist(
  String id,
  String name, {
  bool isExternal = false,
  int? albumCount,
}) => ArtistsTableData(
  isProvisional: false,
  isExternal: isExternal,
  id: id,
  name: name,
  albumCount: albumCount,
);

void main() {
  group('LibraryArtistNameIndex', () {
    test(
      'links a unique loose name but keeps articles and ambiguity safe',
      () async {
        final index = await LibraryArtistNameIndex.build([
          _artist('peas', 'The Black Eyed Peas'),
          _artist('simon', 'Simon & Garfunkel'),
          _artist('a', 'A Band'),
          _artist('the', 'The Band'),
          _artist('jp', '嵐'),
        ]);
        expect(
          index.lookupAll(['Black Eyed Peas'])['black eyed peas']?.id,
          'peas',
        );
        expect(
          index.lookupAll(['Simon and Garfunkel'])['simon and garfunkel']?.id,
          'simon',
        );
        expect(index.lookupAll(['Band']), isEmpty);
        expect(index.lookupAll(['Le Band']), isEmpty);
        expect(index.lookupAll(['嵐'])['嵐']?.id, 'jp');
        expect(index.lookupAll(['The Band'])['the band']?.id, 'the');
      },
    );

    test('matches normalized names', () async {
      final index = await LibraryArtistNameIndex.build([
        _artist('oor', 'ＯＮＥ　ＯＫ　ＲＯＣＫ'),
        _artist('bey', 'Beyoncé'),
        _artist('mfs', 'MY FIRST STORY'),
        _artist('other', 'Someone Else'),
      ]);

      final found = index.lookupAll([
        'One Ok Rock',
        'Beyonce',
        'My First Story',
        'Coldrain',
        '',
      ]);

      expect(found.map((key, artist) => MapEntry(key, artist.id)), {
        'one ok rock': 'oor',
        'beyonce': 'bey',
        'my first story': 'mfs',
      });
    });

    test(
      'a server artist wins over a remote namesake, then more albums',
      () async {
        final index = await LibraryArtistNameIndex.build([
          _artist('remote', 'Coldrain', isExternal: true, albumCount: 40),
          _artist('few', 'coldrain', albumCount: 2),
          _artist('many', 'COLDRAIN', albumCount: 9),
        ]);

        expect(index.lookupAll(['Coldrain'])['coldrain']?.id, 'many');
      },
    );

    test('a large library is keyed in a background isolate', () async {
      final artists = [
        for (var i = 0; i < LibraryArtistNameIndex.isolateThreshold * 3; i++)
          _artist('a$i', 'Artist Número $i'),
      ];

      final index = await LibraryArtistNameIndex.build(artists);

      expect(
        index.lookupAll(['artist numero 150'])['artist numero 150']?.id,
        'a150',
      );
    });
  });

  group('LibraryArtistNameIndexCache', () {
    test('builds once until marked stale', () async {
      var loads = 0;
      final cache = LibraryArtistNameIndexCache(
        loadArtists: () async {
          loads++;
          return [_artist('a', 'A')];
        },
      );

      final first = await cache.current();
      final again = await cache.current();
      expect(again, same(first));
      expect(loads, 1);

      cache.markStale();
      final rebuilt = await cache.current();
      expect(rebuilt, isNot(same(first)));
      expect(loads, 2);
    });

    test('callers at the same time share one build', () async {
      var loads = 0;
      final gate = Completer<void>();
      final cache = LibraryArtistNameIndexCache(
        loadArtists: () async {
          loads++;
          await gate.future;
          return const <ArtistsTableData>[];
        },
      );

      final first = cache.current();
      final second = cache.current();
      gate.complete();

      expect(await second, same(await first));
      expect(loads, 1);
    });

    test('a failed build is not kept', () async {
      var fail = true;
      final cache = LibraryArtistNameIndexCache(
        loadArtists: () async {
          if (fail) throw StateError('database closed');
          return [_artist('a', 'A')];
        },
      );

      await expectLater(cache.current(), throwsStateError);
      fail = false;
      expect((await cache.current()).lookupAll(['A']), hasLength(1));
    });
  });

  test(
    'the provider keeps its index until the artists table changes',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: withTestDatabase(database),
      );
      addTearDown(container.dispose);
      await database
          .into(database.artistsTable)
          .insert(ArtistsTableCompanion.insert(id: 'sim', name: 'SiM'));

      final cache = container.read(libraryArtistNameIndexProvider);
      final first = await cache.current();
      expect(await cache.current(), same(first));
      expect(first.lookupAll(['Coldrain']), isEmpty);

      // A library sync writes artists like this.
      await database
          .into(database.artistsTable)
          .insert(
            ArtistsTableCompanion.insert(
              id: 'cold',
              name: 'Coldrain',
              albumCount: const Value(7),
            ),
          );
      await pumpEventQueue();

      final rebuilt = await cache.current();
      expect(rebuilt, isNot(same(first)));
      expect(rebuilt.lookupAll(['Coldrain'])['coldrain']?.id, 'cold');
    },
  );
}
