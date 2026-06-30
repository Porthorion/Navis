import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/features/library/data/lastfm_artist_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lastfm_cache_test_');

    // Override path_provider to use a temp directory for each test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall methodCall) async {
            if (methodCall.method == 'getApplicationSupportDirectory') {
              return tempDir.path;
            }
            return null;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ---------------------------------------------------------------------------
  // Write → Read roundtrip
  // ---------------------------------------------------------------------------

  test('roundtrip: writeCache then readCache returns same tracks', () async {
    const artist = 'Queen';
    final tracks = [
      const LastFmArtistTopTrack(
        rank: 1,
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
        listeners: 2000000,
      ),
      const LastFmArtistTopTrack(
        rank: 2,
        title: 'We Will Rock You',
        artist: 'Queen',
        listeners: 1500000,
      ),
    ];

    await LastFmArtistCache.writeCache(artist, tracks);
    final result = await LastFmArtistCache.readCache(artist);

    expect(result, isNotNull);
    expect(result, hasLength(2));
    expect(result![0].title, 'Bohemian Rhapsody');
    expect(result[0].rank, 1);
    expect(result[0].listeners, 2000000);
    expect(result[1].title, 'We Will Rock You');
    expect(result[1].rank, 2);
  });

  // ---------------------------------------------------------------------------
  // Artist mismatch rejection
  // ---------------------------------------------------------------------------

  test('readCache rejects entry when cached artist does not match', () async {
    // Write cache for "Queen".
    await LastFmArtistCache.writeCache('Queen', [
      const LastFmArtistTopTrack(
        rank: 1,
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
        listeners: 2000000,
      ),
    ]);

    // Manually tamper: overwrite the file with a different artist field but
    // same filename hash (simulating a collision or leftover file).
    final files = tempDir.listSync().whereType<File>();
    expect(files, isNotEmpty);
    final cacheFile = files.first;
    final json =
        jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
    json['artist'] = 'Freddie Mercury';
    cacheFile.writeAsStringSync(jsonEncode(json));

    // Read with the original artist name — should reject the mismatch.
    final result = await LastFmArtistCache.readCache('Queen');
    expect(result, isNull);
  });

  // ---------------------------------------------------------------------------
  // Stale timestamp rejection
  // ---------------------------------------------------------------------------

  test(
    'readCache rejects entry when fetchedAt is older than 24 hours',
    () async {
      await LastFmArtistCache.writeCache('Queen', [
        const LastFmArtistTopTrack(
          rank: 1,
          title: 'Bohemian Rhapsody',
          artist: 'Queen',
          listeners: 2000000,
        ),
      ]);

      final files = tempDir.listSync().whereType<File>();
      final cacheFile = files.first;
      final json =
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      json['fetchedAt'] = DateTime.now()
          .subtract(const Duration(hours: 24, minutes: 1))
          .toIso8601String();
      cacheFile.writeAsStringSync(jsonEncode(json));

      final result = await LastFmArtistCache.readCache('Queen');
      expect(result, isNull);
    },
  );

  test('readCache accepts entry within rolling 24-hour freshness', () async {
    await LastFmArtistCache.writeCache('Queen', [
      const LastFmArtistTopTrack(
        rank: 1,
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
      ),
    ]);

    final files = tempDir.listSync().whereType<File>();
    final cacheFile = files.first;
    final json =
        jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
    json['fetchedAt'] = DateTime.now()
        .subtract(const Duration(hours: 23, minutes: 59))
        .toIso8601String();
    cacheFile.writeAsStringSync(jsonEncode(json));

    final result = await LastFmArtistCache.readCache('Queen');
    expect(result, isNotNull);
    expect(result!.first.title, 'Bohemian Rhapsody');
  });

  test('readCache rejects entry when requested limit differs', () async {
    await LastFmArtistCache.writeCache(
      'Queen',
      [
        const LastFmArtistTopTrack(
          rank: 1,
          title: 'Bohemian Rhapsody',
          artist: 'Queen',
        ),
      ],
      limit: 10,
    );

    final result = await LastFmArtistCache.readCache('Queen', limit: 50);
    expect(result, isNull);
  });

  // ---------------------------------------------------------------------------
  // Missing artist field in legacy cache
  // ---------------------------------------------------------------------------

  test('readCache rejects legacy entry without artist field', () async {
    // Write a cache file in the old format (no "artist" key).
    await LastFmArtistCache.writeCache('Queen', [
      const LastFmArtistTopTrack(
        rank: 1,
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
      ),
    ]);

    final files = tempDir.listSync().whereType<File>();
    final cacheFile = files.first;
    final json =
        jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
    json.remove('artist');
    cacheFile.writeAsStringSync(jsonEncode(json));

    // Legacy file without artist field should be treated as a miss.
    final result = await LastFmArtistCache.readCache('Queen');
    expect(result, isNull);
  });

  // ---------------------------------------------------------------------------
  // Hash-based key uniqueness
  // ---------------------------------------------------------------------------

  test('different artists produce different cache file names', () async {
    await LastFmArtistCache.writeCache('Artist One', [
      const LastFmArtistTopTrack(
        rank: 1,
        title: 'Song A',
        artist: 'Artist One',
      ),
    ]);
    await LastFmArtistCache.writeCache('Artist Two', [
      const LastFmArtistTopTrack(
        rank: 1,
        title: 'Song B',
        artist: 'Artist Two',
      ),
    ]);

    // Both files should exist (distinct hash keys).
    final files = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('lastfm_top_'))
        .toList();
    expect(files.length, 2);

    // Each file should return its own artist's data.
    final one = await LastFmArtistCache.readCache('Artist One');
    final two = await LastFmArtistCache.readCache('Artist Two');
    expect(one, isNotNull);
    expect(two, isNotNull);
    expect(one!.first.title, 'Song A');
    expect(two!.first.title, 'Song B');
  });

  test(
    'previously-colliding artists now get distinct cache keys',
    () async {
      // "Artist-One" and "Artist One" used to both map to "artist_one" with
      // the old regex-based sanitiser.  With SHA-256 hashing they should be
      // completely distinct.
      final hashA = sha256
          .convert(utf8.encode('artist-one'))
          .toString()
          .substring(0, 16);
      final hashB = sha256
          .convert(utf8.encode('artist one'))
          .toString()
          .substring(0, 16);
      expect(hashA, isNot(equals(hashB)));

      await LastFmArtistCache.writeCache('Artist-One', [
        const LastFmArtistTopTrack(
          rank: 1,
          title: 'Dash Song',
          artist: 'Artist-One',
        ),
      ]);
      await LastFmArtistCache.writeCache('Artist One', [
        const LastFmArtistTopTrack(
          rank: 1,
          title: 'Space Song',
          artist: 'Artist One',
        ),
      ]);

      final dash = await LastFmArtistCache.readCache('Artist-One');
      final space = await LastFmArtistCache.readCache('Artist One');
      expect(dash, isNotNull);
      expect(space, isNotNull);
      expect(dash!.first.title, 'Dash Song');
      expect(space!.first.title, 'Space Song');
    },
  );

  // ---------------------------------------------------------------------------
  // Empty tracks not cached
  // ---------------------------------------------------------------------------

  test('writeCache is a no-op for an empty track list', () async {
    await LastFmArtistCache.writeCache('Nobody', const []);

    final files = tempDir.listSync().whereType<File>().where(
      (f) => f.path.contains('lastfm_top_'),
    );
    expect(files, isEmpty);

    final result = await LastFmArtistCache.readCache('Nobody');
    expect(result, isNull);
  });

  // ---------------------------------------------------------------------------
  // Case-insensitive artist matching
  // ---------------------------------------------------------------------------

  test('readCache matches artist name case-insensitively', () async {
    await LastFmArtistCache.writeCache('Queen', [
      const LastFmArtistTopTrack(
        rank: 1,
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
      ),
    ]);

    // Read with different casing — should still hit because both
    // "queen" == "queen" after normalisation, and cache key is hash-based
    // on lowercased name so the same file is accessed.
    final result = await LastFmArtistCache.readCache('queen');
    expect(result, isNotNull);
    expect(result!.first.title, 'Bohemian Rhapsody');
  });
}
