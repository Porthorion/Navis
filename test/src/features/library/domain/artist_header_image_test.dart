import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/domain/artist_header_image.dart';

const _server = 'https://music.example.org/rest/getCoverArt.view?id=ar-1';
const _lastFmPhoto =
    'https://lastfm.freetls.fastly.net/i/u/300x300/0f0b9a1b2c.jpg';
const _lastFmStar =
    'https://lastfm.freetls.fastly.net/i/u/300x300/'
    '2a96cbd8b46e442fc41c2b86b821562f.png';
const _deezer =
    'https://cdn-images.dzcdn.net/images/artist/c4d6/1000x1000-000000-80-0-0.jpg';
const _deezerBlank =
    'https://cdn-images.dzcdn.net/images/artist//1000x1000-000000-80-0-0.jpg';

void main() {
  test('isLastFmPlaceholderUrl recognises the grey star in any size', () {
    expect(isLastFmPlaceholderUrl(_lastFmStar), isTrue);
    expect(
      isLastFmPlaceholderUrl(
        'https://lastfm.freetls.fastly.net/i/u/174s/'
        '2A96CBD8B46E442FC41C2B86B821562F.png',
      ),
      isTrue,
    );
    expect(isLastFmPlaceholderUrl(_lastFmPhoto), isFalse);
    expect(isLastFmPlaceholderUrl(''), isFalse);
  });

  test('isDeezerPlaceholderPictureUrl recognises a picture without hash', () {
    expect(isDeezerPlaceholderPictureUrl(_deezerBlank), isTrue);
    expect(isDeezerPlaceholderPictureUrl(_deezer), isFalse);
  });

  group('artistHeaderImageUrls', () {
    test('the server photo comes first, then Deezer', () {
      expect(
        artistHeaderImageUrls(
          serverLargeImageUrl: _server,
          deezerPictureUrl: _deezer,
        ),
        [_server, _deezer],
      );
    });

    test('an empty large URL falls through to the medium one', () {
      expect(
        artistHeaderImageUrls(
          serverLargeImageUrl: '  ',
          serverMediumImageUrl: _lastFmPhoto,
        ),
        [_lastFmPhoto],
      );
    });

    test('an empty server URL leaves Deezer', () {
      expect(
        artistHeaderImageUrls(
          serverLargeImageUrl: '',
          serverMediumImageUrl: '',
          deezerPictureUrl: _deezer,
        ),
        [_deezer],
      );
    });

    test('the Last.fm star is no photo', () {
      expect(
        artistHeaderImageUrls(
          serverLargeImageUrl: _lastFmStar,
          serverMediumImageUrl: _lastFmStar,
          deezerPictureUrl: _deezer,
        ),
        [_deezer],
      );
      expect(artistHeaderImageUrls(serverLargeImageUrl: _lastFmStar), isEmpty);
    });

    test('a URL that does not parse is no photo', () {
      expect(
        artistHeaderImageUrls(
          serverLargeImageUrl: 'http://[::1',
          serverMediumImageUrl: 'not a url',
          deezerPictureUrl: _deezer,
        ),
        [_deezer],
      );
    });

    test("Deezer's blank picture is no photo", () {
      expect(artistHeaderImageUrls(deezerPictureUrl: _deezerBlank), isEmpty);
    });

    test('without Deezer only the server photo is tried', () {
      expect(artistHeaderImageUrls(serverLargeImageUrl: _server), [_server]);
      expect(artistHeaderImageUrls(), isEmpty);
    });
  });
}
