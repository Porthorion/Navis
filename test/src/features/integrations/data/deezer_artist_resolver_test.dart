import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/features/integrations/data/deezer_artist_resolver.dart';
import 'package:navis/src/features/integrations/data/deezer_cache.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';

class _FakeDeezer extends DeezerApiClient {
  new() : super(dio: Dio());

  List<DeezerArtist> artists = const [];
  Map<int, List<DeezerAlbum>> albumsByArtist = const {};
  Exception? searchError;

  /// Thrown by the album lookup of the artist with that id.
  Map<int, Exception> albumErrors = <int, Exception>{};
  int searchCalls = 0;

  /// Holds every search until completed.
  Completer<void>? searchGate;
  final List<int> albumCalls = <int>[];

  @override
  Future<List<DeezerArtist>> searchArtists(
    String name, {
    int limit = 25,
    CancelToken? cancelToken,
  }) async {
    searchCalls++;
    if (searchGate case final gate?) await gate.future;
    if (cancelToken?.isCancelled ?? false) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: 'search/artist'),
        reason: 'left',
      );
    }
    if (searchError case final error?) throw error;
    return artists;
  }

  @override
  Future<List<DeezerAlbum>> getArtistAlbums(
    int artistId, {
    int limit = 100,
    CancelToken? cancelToken,
  }) async {
    albumCalls.add(artistId);
    if (albumErrors[artistId] case final error?) throw error;
    return albumsByArtist[artistId] ?? const [];
  }
}

List<DeezerAlbum> _albums(List<String> titles) => [
  for (var i = 0; i < titles.length; i++)
    DeezerAlbum(id: i + 1, title: titles[i]),
];

void main() {
  late Directory root;
  late DateTime now;
  late _FakeDeezer deezer;
  late DeezerArtistResolver resolver;

  setUp(() {
    root = Directory.systemTemp.createTempSync('deezer_artist_resolver_');
    now = DateTime.utc(2026, 10, 5);
    deezer = _FakeDeezer();
    resolver = DeezerArtistResolver(
      client: deezer,
      cache: IntegrationJsonCache(
        readRootDirectory: () async => root,
        now: () => now,
      ),
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('library namesakes and accounts keep separate mappings', () async {
    deezer.artists = const [
      DeezerArtist(id: 1, name: 'Namesake', fanCount: 100),
      DeezerArtist(id: 2, name: 'Namesake', fanCount: 10),
    ];
    deezer.albumsByArtist = {
      1: _albums(['First']),
      2: _albums(['Second']),
    };
    Future<int?> resolve(
      DeezerArtistResolver owner,
      String artistId,
      String album,
    ) => owner.resolve(
      artistId: artistId,
      name: 'Namesake',
      readLibraryAlbumTitles: () async => [album],
    );
    // Two library artists of one name: the second is not given the
    // first's cached mapping.
    expect(await resolve(resolver, 'a', 'First'), 1);
    expect(await resolve(resolver, 'b', 'Second'), 2);
    // Each is then served from its own cached mapping.
    final searches = deezer.searchCalls;
    expect(await resolve(resolver, 'a', 'First'), 1);
    expect(await resolve(resolver, 'b', 'Second'), 2);
    expect(deezer.searchCalls, searches);
    // Another account with the same artist id resolves on its own.
    final other = DeezerArtistResolver(
      client: deezer,
      cache: IntegrationJsonCache(readRootDirectory: () async => root),
      accountScope: 'other',
    );
    expect(await resolve(other, 'a', 'Second'), 2);
    expect(deezer.searchCalls, searches + 1);
  });

  test('an ext-deezer-artist id is used without a request', () async {
    final id = await resolver.resolve(
      artistId: 'ext-deezer-artist-416239',
      name: 'Anything',
    );

    expect(id, 416239);
    expect(deezer.searchCalls, 0);
    expect(DeezerArtistResolver.idFromLibraryArtistId('artist-1'), isNull);
  });

  test('only an exact normalized name matches', () async {
    deezer.artists = const [
      DeezerArtist(id: 1, name: 'Imagine Dragons & K.Flay', fanCount: 300),
      DeezerArtist(id: 2, name: 'IMAGINE DRAGONS', fanCount: 9000000),
    ];

    expect(await resolver.resolve(artistId: 'a1', name: 'Imagine Dragons'), 2);
  });

  test('Unicode names match after normalization', () async {
    deezer.artists = const [
      DeezerArtist(id: 7, name: 'ＯＮＥ　ＯＫ　ＲＯＣＫ', fanCount: 10),
      DeezerArtist(id: 8, name: 'Beyoncé', fanCount: 10),
    ];

    expect(await resolver.resolve(artistId: 'a', name: 'ONE OK ROCK'), 7);
    expect(await resolver.resolve(artistId: 'b', name: 'Beyonce'), 8);
  });

  group('names that differ only in form', () {
    /// The library artist's album titles, as the artist page reads them.
    Future<Iterable<String>> Function() libraryAlbums(List<String> titles) =>
        () async => titles;

    test(
      'a leading "The" on either side resolves with a shared album',
      () async {
        deezer
          ..artists = const [
            DeezerArtist(
              id: 1020109,
              name: 'Black Eyed Peas',
              fanCount: 6110407,
            ),
            DeezerArtist(
              id: 4189978,
              name: 'Made famous by The Black Eyed Peas',
              fanCount: 440,
            ),
            DeezerArtist(
              id: 189221687,
              name: 'Black Eyed Peas & Daddy Yankee',
              fanCount: 38,
            ),
            DeezerArtist(id: 1, name: 'The Beatles', fanCount: 100),
          ]
          ..albumsByArtist = {
            1020109: _albums(['Elephunk', 'Monkey Business']),
            1: _albums(['Abbey Road']),
          };

        expect(
          await resolver.resolve(
            artistId: 'bep',
            name: 'The Black Eyed Peas',
            readLibraryAlbumTitles: libraryAlbums(['Elephunk']),
          ),
          1020109,
        );
        expect(
          await resolver.resolve(
            artistId: 'b',
            name: 'Beatles',
            readLibraryAlbumTitles: libraryAlbums(['Abbey Road (Remastered)']),
          ),
          1,
        );
      },
    );

    test('"&" and "and" are the same', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 2707, name: 'Simon & Garfunkel', fanCount: 1167649),
          DeezerArtist(
            id: 74334152,
            name: 'Simon & Garfunkel Experience',
            fanCount: 226,
          ),
        ]
        ..albumsByArtist = {
          2707: _albums(['Bookends']),
        };

      expect(
        await resolver.resolve(
          artistId: 'sg',
          name: 'Simon and Garfunkel',
          readLibraryAlbumTitles: libraryAlbums(['Bookends']),
        ),
        2707,
      );
    });

    test('spacing and punctuation do not matter', () async {
      deezer
        ..artists = const [DeezerArtist(id: 115, name: 'AC/DC')]
        ..albumsByArtist = {
          115: _albums(['Back in Black']),
        };

      expect(
        await resolver.resolve(
          artistId: 'acdc',
          name: 'ACDC',
          readLibraryAlbumTitles: libraryAlbums(['Back In Black']),
        ),
        115,
      );
    });

    test('Los, La, Die and Der are articles too', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 1, name: 'Los Lobos'),
          DeezerArtist(id: 2, name: 'Toten Hosen'),
        ]
        ..albumsByArtist = {
          1: _albums(['Kiko']),
          2: _albums(['Opium fürs Volk']),
        };

      expect(
        await resolver.resolve(
          artistId: 'l',
          name: 'Lobos',
          readLibraryAlbumTitles: libraryAlbums(['Kiko']),
        ),
        1,
      );
      expect(
        await resolver.resolve(
          artistId: 't',
          name: 'Die Toten Hosen',
          readLibraryAlbumTitles: libraryAlbums(['Opium fürs Volk']),
        ),
        2,
      );
    });

    test('two different articles never match', () async {
      deezer
        ..artists = const [DeezerArtist(id: 2, name: 'The Band', fanCount: 500)]
        ..albumsByArtist = {
          2: _albums(['Shared Title']),
        };

      // Even an album title in common does not make "A Band" "The Band".
      expect(
        await resolver.resolve(
          artistId: 'ab',
          name: 'A Band',
          readLibraryAlbumTitles: libraryAlbums(['Shared Title']),
        ),
        isNull,
      );
      expect(deezer.albumCalls, isEmpty);
    });

    test(
      'a single loose candidate without a shared album is rejected',
      () async {
        deezer
          ..artists = const [
            DeezerArtist(id: 7, name: 'BIGBANG', fanCount: 900000),
          ]
          ..albumsByArtist = {
            7: _albums(['MADE', 'Alive']),
          };

        expect(
          await resolver.resolve(
            artistId: 'bb',
            name: 'Big Bang',
            readLibraryAlbumTitles: libraryAlbums(['Some Local Band Album']),
          ),
          isNull,
        );
        expect(deezer.albumCalls, [7]);
      },
    );

    test('no loose match is accepted without library albums', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 1020109, name: 'Black Eyed Peas', fanCount: 6110407),
        ]
        ..albumsByArtist = {
          1020109: _albums(['Elephunk']),
        };

      expect(
        await resolver.resolve(artistId: 'bep', name: 'The Black Eyed Peas'),
        isNull,
      );
      // Nor when the library lists no album titles.
      now = now.add(DeezerCache.artistNotFoundTtl);
      expect(
        await resolver.resolve(
          artistId: 'bep',
          name: 'The Black Eyed Peas',
          readLibraryAlbumTitles: libraryAlbums(const []),
        ),
        isNull,
      );
      expect(deezer.searchCalls, 2);
      expect(deezer.albumCalls, isEmpty);
    });

    test('an exact name wins over a looser one with more fans', () async {
      deezer.artists = const [
        DeezerArtist(id: 1, name: 'Band', fanCount: 900000),
        DeezerArtist(id: 2, name: 'The Band', fanCount: 500),
      ];

      expect(await resolver.resolve(artistId: 'tb', name: 'The Band'), 2);
    });

    test('loose namesakes go to the most shared albums', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 1020109, name: 'Black Eyed Peas', fanCount: 6110407),
          DeezerArtist(id: 414191872, name: 'Black Eyed Peas', fanCount: 0),
        ]
        ..albumsByArtist = {
          1020109: _albums(['Something Else']),
          414191872: _albums(['Elephunk']),
        };

      final id = await resolver.resolve(
        artistId: 'bep',
        name: 'The Black Eyed Peas',
        readLibraryAlbumTitles: libraryAlbums(['Elephunk']),
      );

      expect(id, 414191872);
      expect(deezer.albumCalls, [1020109, 414191872]);
    });

    test('"The The" is not the artist "The", nor another "The" band', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 1, name: 'The', fanCount: 9000),
          DeezerArtist(id: 2, name: 'The Weeknd', fanCount: 14720452),
        ]
        ..albumsByArtist = {
          1: _albums(['Soul Mining']),
          2: _albums(['Soul Mining']),
        };

      expect(
        await resolver.resolve(
          artistId: 'tt',
          name: 'The The',
          readLibraryAlbumTitles: libraryAlbums(['Soul Mining']),
        ),
        isNull,
      );
    });

    test('"The The" resolves to itself and "The" not to it', () async {
      deezer.artists = const [
        DeezerArtist(id: 57420412, name: 'TheThe', fanCount: 51),
        DeezerArtist(id: 4131, name: 'The The', fanCount: 25433),
      ];

      expect(await resolver.resolve(artistId: 'tt', name: 'The The'), 4131);
      expect(await resolver.resolve(artistId: 'the', name: 'The'), isNull);
    });

    test('a "not on Deezer" from before loose names is asked again', () async {
      // What an earlier build cached for "The Black Eyed Peas".
      await IntegrationJsonCache(
        readRootDirectory: () async => root,
        now: () => now,
      ).write(
        DeezerCache.artistIdNamespace,
        'the black eyed peas',
        <String, Object?>{'id': null},
        ttl: DeezerCache.artistNotFoundTtl,
      );
      deezer
        ..artists = const [
          DeezerArtist(id: 1020109, name: 'Black Eyed Peas', fanCount: 6110407),
        ]
        ..albumsByArtist = {
          1020109: _albums(['Elephunk']),
        };

      expect(
        await resolver.resolve(
          artistId: 'bep',
          name: 'The Black Eyed Peas',
          readLibraryAlbumTitles: libraryAlbums(['Elephunk']),
        ),
        1020109,
      );
      expect(deezer.searchCalls, 1);
    });
  });

  test('namesakes go to the most fans without library albums', () async {
    deezer.artists = const [
      DeezerArtist(id: 10, name: 'Nirvana', fanCount: 5000),
      DeezerArtist(id: 11, name: 'Nirvana', fanCount: 9000000),
    ];

    expect(await resolver.resolve(artistId: 'n', name: 'Nirvana'), 11);
    expect(deezer.albumCalls, isEmpty);
  });

  test('namesakes go to the one sharing library album titles', () async {
    deezer
      ..artists = const [
        DeezerArtist(id: 11, name: 'Nirvana', fanCount: 9000000),
        DeezerArtist(id: 10, name: 'Nirvana', fanCount: 5000),
      ]
      ..albumsByArtist = {
        11: _albums(['Nevermind', 'In Utero']),
        10: _albums(['The Story of Simon Simopath', 'All of Us']),
      };

    final id = await resolver.resolve(
      artistId: 'n',
      name: 'Nirvana',
      readLibraryAlbumTitles: () async => ['All Of Us (Remastered)'],
    );

    expect(id, 10);
    expect(deezer.albumCalls, [11, 10]);
  });

  test('equal album overlap keeps the artist with more fans', () async {
    deezer
      ..artists = const [
        DeezerArtist(id: 10, name: 'Nirvana', fanCount: 5000),
        DeezerArtist(id: 11, name: 'Nirvana', fanCount: 9000000),
      ]
      ..albumsByArtist = {
        11: _albums(['Nevermind']),
        10: _albums(['Nevermind']),
      };

    final id = await resolver.resolve(
      artistId: 'n',
      name: 'Nirvana',
      readLibraryAlbumTitles: () async => ['Unrelated'],
    );

    expect(id, 11);
  });

  test('album overlap compares at most three namesakes', () async {
    deezer.artists = [
      for (var i = 1; i <= 5; i++)
        DeezerArtist(id: i, name: 'Common', fanCount: 100 - i),
    ];

    await resolver.resolve(
      artistId: 'c',
      name: 'Common',
      readLibraryAlbumTitles: () async => ['Be'],
    );

    expect(deezer.albumCalls, [1, 2, 3]);
  });

  test('the mapping is cached for 30 days', () async {
    deezer.artists = const [DeezerArtist(id: 412, name: 'Queen')];

    expect(await resolver.resolve(artistId: 'q', name: 'Queen'), 412);
    now = now.add(const Duration(days: 29));
    expect(await resolver.resolve(artistId: 'q', name: 'queen'), 412);
    expect(deezer.searchCalls, 1);

    now = now.add(DeezerCache.artistFoundTtl);
    await resolver.resolve(artistId: 'q', name: 'Queen');
    expect(deezer.searchCalls, 2);
  });

  test('"not on Deezer" is cached for 7 days', () async {
    deezer.artists = const [DeezerArtist(id: 1, name: 'Someone Else')];

    expect(await resolver.resolve(artistId: 'x', name: 'Unknown'), isNull);
    now = now.add(const Duration(days: 6));
    expect(await resolver.resolve(artistId: 'x', name: 'Unknown'), isNull);
    expect(deezer.searchCalls, 1);

    now = now.add(const Duration(days: 1));
    await resolver.resolve(artistId: 'x', name: 'Unknown');
    expect(deezer.searchCalls, 2);
  });

  test('a failed search is not cached', () async {
    deezer.searchError = const DeezerApiException(code: 4);

    await expectLater(
      resolver.resolve(artistId: 'q', name: 'Queen'),
      throwsA(isA<DeezerApiException>()),
    );

    deezer
      ..searchError = null
      ..artists = const [DeezerArtist(id: 412, name: 'Queen')];
    expect(await resolver.resolve(artistId: 'q', name: 'Queen'), 412);
  });

  group('an inconclusive resolution is not cached', () {
    const quota = DeezerApiException(code: 4, message: 'Quota limit exceeded');

    test('a failed album lookup for a loose match caches nothing', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 1020109, name: 'Black Eyed Peas', fanCount: 6110407),
        ]
        ..albumsByArtist = {
          1020109: _albums(['Elephunk']),
        }
        ..albumErrors = {1020109: quota};
      Future<int?> resolve() => resolver.resolve(
        artistId: 'bep',
        name: 'The Black Eyed Peas',
        readLibraryAlbumTitles: () async => ['Elephunk'],
      );

      expect(await resolve(), isNull);

      // The next visit asks again, and caches what it finds.
      deezer.albumErrors = {};
      expect(await resolve(), 1020109);
      expect(deezer.searchCalls, 2);
      expect(await resolve(), 1020109);
      expect(deezer.searchCalls, 2);
    });

    test('a failed lookup stops comparing the other candidates', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 1, name: 'Black Eyed Peas', fanCount: 100),
          DeezerArtist(id: 2, name: 'Black Eyed Peas', fanCount: 10),
        ]
        ..albumsByArtist = {
          2: _albums(['Elephunk']),
        }
        ..albumErrors = {1: quota};

      expect(
        await resolver.resolve(
          artistId: 'bep',
          name: 'The Black Eyed Peas',
          readLibraryAlbumTitles: () async => ['Elephunk'],
        ),
        isNull,
      );
      expect(deezer.albumCalls, [1]);
    });

    test('a failed namesake lookup answers the most fans uncached', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 10, name: 'Nirvana', fanCount: 5000),
          DeezerArtist(id: 11, name: 'Nirvana', fanCount: 9000000),
        ]
        ..albumsByArtist = {
          10: _albums(['All of Us']),
        }
        ..albumErrors = {11: quota};
      Future<int?> resolve() => resolver.resolve(
        artistId: 'n',
        name: 'Nirvana',
        readLibraryAlbumTitles: () async => ['All of Us'],
      );

      expect(await resolve(), 11);

      deezer.albumErrors = {};
      expect(await resolve(), 10);
      expect(deezer.searchCalls, 2);
      expect(await resolve(), 10);
      expect(deezer.searchCalls, 2);
    });

    test('a transport failure is inconclusive too', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 1020109, name: 'Black Eyed Peas', fanCount: 6110407),
        ]
        ..albumErrors = {
          1020109: DioException.connectionTimeout(
            timeout: const Duration(seconds: 8),
            requestOptions: RequestOptions(path: 'artist/1020109/albums'),
          ),
        };
      Future<int?> resolve() => resolver.resolve(
        artistId: 'bep',
        name: 'The Black Eyed Peas',
        readLibraryAlbumTitles: () async => ['Elephunk'],
      );

      expect(await resolve(), isNull);
      await resolve();
      expect(deezer.searchCalls, 2);
    });

    test('a cancelled album lookup still propagates', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 1020109, name: 'Black Eyed Peas', fanCount: 6110407),
        ]
        ..albumErrors = {
          1020109: DioException.requestCancelled(
            requestOptions: RequestOptions(path: 'artist/1020109/albums'),
            reason: 'left',
          ),
        };

      await expectLater(
        resolver.resolve(
          artistId: 'bep',
          name: 'The Black Eyed Peas',
          readLibraryAlbumTitles: () async => ['Elephunk'],
        ),
        throwsA(isA<DioException>()),
      );
    });

    test('a loose match sharing no album, all lookups answered, is cached '
        'as not on Deezer', () async {
      deezer
        ..artists = const [
          DeezerArtist(id: 1020109, name: 'Black Eyed Peas', fanCount: 6110407),
        ]
        ..albumsByArtist = {
          1020109: _albums(['Something Else']),
        };
      Future<int?> resolve() => resolver.resolve(
        artistId: 'bep',
        name: 'The Black Eyed Peas',
        readLibraryAlbumTitles: () async => ['Elephunk'],
      );

      expect(await resolve(), isNull);
      now = now.add(const Duration(days: 6));
      expect(await resolve(), isNull);
      expect(deezer.searchCalls, 1);
      now = now.add(const Duration(days: 1));
      await resolve();
      expect(deezer.searchCalls, 2);
    });
  });

  test('callers resolving the same name at once share one search', () async {
    deezer
      ..artists = const [DeezerArtist(id: 412, name: 'Queen')]
      ..searchGate = Completer<void>();

    final first = resolver.resolve(artistId: 'q', name: 'Queen');
    final second = resolver.resolve(artistId: 'q', name: 'QUEEN');
    await pumpEventQueue();
    deezer.searchGate!.complete();

    expect(await Future.wait([first, second]), [412, 412]);
    expect(deezer.searchCalls, 1);
  });

  test('a caller resolves again when the one it shared with left', () async {
    deezer
      ..artists = const [DeezerArtist(id: 412, name: 'Queen')]
      ..searchGate = Completer<void>();
    final leaving = CancelToken();

    final first = resolver.resolve(
      artistId: 'q',
      name: 'Queen',
      cancelToken: leaving,
    );
    final second = resolver.resolve(
      artistId: 'q',
      name: 'Queen',
      cancelToken: CancelToken(),
    );
    await pumpEventQueue();
    leaving.cancel();
    deezer.searchGate!.complete();

    await expectLater(first, throwsA(isA<DioException>()));
    expect(await second, 412);
    expect(deezer.searchCalls, 2);
  });
}
