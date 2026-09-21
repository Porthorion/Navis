import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';

void main() {
  group('Freezed model serialization', () {
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
  });
}
