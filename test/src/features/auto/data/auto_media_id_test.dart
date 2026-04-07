import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auto/data/auto_media_id.dart';

void main() {
  group('AutoMediaRoot constants', () {
    test('root constants have expected values', () {
      expect(AutoMediaRoot.root, 'root');
      expect(AutoMediaRoot.playlists, 'root/playlists');
      expect(AutoMediaRoot.artists, 'root/artists');
      expect(AutoMediaRoot.albums, 'root/albums');
      expect(AutoMediaRoot.liked, 'root/liked');
      expect(AutoMediaRoot.recent, 'root/recent');
      expect(AutoMediaRoot.randomMix, 'root/random');
      expect(AutoMediaRoot.likedSongs, 'liked/songs');
      expect(AutoMediaRoot.likedAlbums, 'liked/albums');
    });
  });

  group('AutoMediaId encoding', () {
    test('artist encodes correctly', () {
      expect(AutoMediaId.artist('123'), 'artist/123');
      expect(AutoMediaId.artist('abc-def'), 'artist/abc-def');
    });

    test('album encodes correctly', () {
      expect(AutoMediaId.album('456'), 'album/456');
    });

    test('playlist encodes correctly', () {
      expect(AutoMediaId.playlist('789'), 'playlist/789');
    });

    test('song encodes correctly', () {
      expect(AutoMediaId.song('s1'), 'song/s1');
    });
  });

  group('AutoMediaId.parse', () {
    test('parses root', () {
      final parsed = AutoMediaId.parse('root');
      expect(parsed, isNotNull);
      expect(parsed!.type, AutoMediaIdType.root);
      expect(parsed.entityId, isNull);
    });

    test('parses root categories', () {
      for (final id in [
        AutoMediaRoot.playlists,
        AutoMediaRoot.artists,
        AutoMediaRoot.albums,
        AutoMediaRoot.liked,
        AutoMediaRoot.recent,
        AutoMediaRoot.randomMix,
      ]) {
        final parsed = AutoMediaId.parse(id);
        expect(parsed, isNotNull, reason: 'Failed to parse: $id');
        expect(parsed!.type, AutoMediaIdType.rootCategory);
        expect(parsed.entityId, isNull);
      }
    });

    test('parses liked subcategories', () {
      final likedSongs = AutoMediaId.parse(AutoMediaRoot.likedSongs);
      expect(likedSongs, isNotNull);
      expect(likedSongs!.type, AutoMediaIdType.likedSubcategory);
      expect(likedSongs.entityId, isNull);

      final likedAlbums = AutoMediaId.parse(AutoMediaRoot.likedAlbums);
      expect(likedAlbums, isNotNull);
      expect(likedAlbums!.type, AutoMediaIdType.likedSubcategory);
      expect(likedAlbums.entityId, isNull);
    });

    test('parses artist entity', () {
      final parsed = AutoMediaId.parse('artist/123');
      expect(parsed, isNotNull);
      expect(parsed!.type, AutoMediaIdType.artist);
      expect(parsed.entityId, '123');
    });

    test('parses album entity', () {
      final parsed = AutoMediaId.parse('album/456');
      expect(parsed, isNotNull);
      expect(parsed!.type, AutoMediaIdType.album);
      expect(parsed.entityId, '456');
    });

    test('parses playlist entity', () {
      final parsed = AutoMediaId.parse('playlist/789');
      expect(parsed, isNotNull);
      expect(parsed!.type, AutoMediaIdType.playlist);
      expect(parsed.entityId, '789');
    });

    test('parses song entity', () {
      final parsed = AutoMediaId.parse('song/s1');
      expect(parsed, isNotNull);
      expect(parsed!.type, AutoMediaIdType.song);
      expect(parsed.entityId, 's1');
    });

    test('handles IDs with multiple slashes', () {
      // "song/some/nested/id" → prefix is "song", entityId is "some/nested/id"
      // Current implementation only splits on first slash
      final parsed = AutoMediaId.parse('song/some/nested/id');
      expect(parsed, isNotNull);
      expect(parsed!.type, AutoMediaIdType.song);
      expect(parsed.entityId, 'some/nested/id');
    });

    test('returns null for empty string', () {
      expect(AutoMediaId.parse(''), isNull);
    });

    test('returns null for unknown prefix', () {
      expect(AutoMediaId.parse('genre/rock'), isNull);
    });

    test('returns null for prefix-only (no ID)', () {
      expect(AutoMediaId.parse('artist/'), isNull);
    });

    test('returns null for slash-only', () {
      expect(AutoMediaId.parse('/'), isNull);
    });
  });

  group('Roundtrip encoding/decoding', () {
    test('artist roundtrips', () {
      const id = 'art-42';
      final encoded = AutoMediaId.artist(id);
      final parsed = AutoMediaId.parse(encoded);
      expect(parsed!.type, AutoMediaIdType.artist);
      expect(parsed.entityId, id);
    });

    test('album roundtrips', () {
      const id = 'alb-99';
      final encoded = AutoMediaId.album(id);
      final parsed = AutoMediaId.parse(encoded);
      expect(parsed!.type, AutoMediaIdType.album);
      expect(parsed.entityId, id);
    });

    test('playlist roundtrips', () {
      const id = 'pl-7';
      final encoded = AutoMediaId.playlist(id);
      final parsed = AutoMediaId.parse(encoded);
      expect(parsed!.type, AutoMediaIdType.playlist);
      expect(parsed.entityId, id);
    });

    test('song roundtrips', () {
      const id = 'song-1234';
      final encoded = AutoMediaId.song(id);
      final parsed = AutoMediaId.parse(encoded);
      expect(parsed!.type, AutoMediaIdType.song);
      expect(parsed.entityId, id);
    });
  });
}
