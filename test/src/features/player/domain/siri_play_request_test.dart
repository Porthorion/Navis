import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/siri_play_request.dart';

void main() {
  NavisAndroidAutoSearchRequest parsed(Map<Object?, Object?> args) {
    final request = siriPlayMediaRequest(args);
    return navisAndroidAutoSearchRequest(request.query, request.extras);
  }

  void expectSearch(
    Map<Object?, Object?> args,
    NavisAndroidAutoSearchType type,
    String term,
  ) {
    final result = parsed(args);
    expect(result.type, type);
    expect(result.term, term);
  }

  test('song carries title, artist and album on the song focus', () {
    final request = siriPlayMediaRequest({
      'mediaType': 'song',
      'mediaName': 'Hurt',
      'artistName': 'Johnny Cash',
      'albumName': 'American IV',
    });
    expect(request.query, 'Hurt');
    expect(request.extras, {
      AndroidAutoConstants.mediaFocusKey: AndroidAutoConstants.mediaFocusSong,
      AndroidAutoConstants.mediaTitleKey: 'Hurt',
      AndroidAutoConstants.mediaArtistKey: 'Johnny Cash',
      AndroidAutoConstants.mediaAlbumKey: 'American IV',
    });
    expectSearch(
      {'mediaType': 'song', 'mediaName': 'Hurt'},
      NavisAndroidAutoSearchType.title,
      'Hurt',
    );
  });

  test('album uses the media name, then the album name', () {
    expectSearch(
      {'mediaType': 'album', 'mediaName': 'Abbey Road', 'artistName': 'x'},
      NavisAndroidAutoSearchType.album,
      'Abbey Road',
    );
    expectSearch(
      {'mediaType': 'album', 'albumName': 'Revolver'},
      NavisAndroidAutoSearchType.album,
      'Revolver',
    );
    final request = siriPlayMediaRequest({
      'mediaType': 'album',
      'mediaName': 'Abbey Road',
      'artistName': 'The Beatles',
    });
    expect(request.extras[AndroidAutoConstants.mediaArtistKey], 'The Beatles');
  });

  test('artist uses the media name, then the artist name', () {
    expectSearch(
      {'mediaType': 'artist', 'mediaName': 'Radiohead'},
      NavisAndroidAutoSearchType.artist,
      'Radiohead',
    );
    expectSearch(
      {'mediaType': 'artist', 'artistName': 'Bjork'},
      NavisAndroidAutoSearchType.artist,
      'Bjork',
    );
  });

  test('playlist and genre map to their searches', () {
    expectSearch(
      {'mediaType': 'playlist', 'mediaName': 'Road trip'},
      NavisAndroidAutoSearchType.playlist,
      'Road trip',
    );
    expectSearch(
      {'mediaType': 'genre', 'mediaName': 'Jazz'},
      NavisAndroidAutoSearchType.genre,
      'Jazz',
    );
    expectSearch(
      {'mediaType': 'genre', 'genreName': 'Blues'},
      NavisAndroidAutoSearchType.genre,
      'Blues',
    );
  });

  test('music and unknown types search generally by name', () {
    for (final type in ['music', 'unknown', 'podcast', null]) {
      final request = siriPlayMediaRequest({
        'mediaType': type,
        'mediaName': 'Nirvana',
      });
      expect(request.query, 'Nirvana');
      expect(request.extras, isEmpty);
      expectSearch(
        {'mediaType': type, 'mediaName': 'Nirvana'},
        NavisAndroidAutoSearchType.general,
        'Nirvana',
      );
    }
  });

  test('without a media name music falls back to artist, then album', () {
    expectSearch(
      {'mediaType': 'music', 'artistName': 'Portishead'},
      NavisAndroidAutoSearchType.artist,
      'Portishead',
    );
    expectSearch(
      {'mediaType': 'unknown', 'albumName': 'Dummy'},
      NavisAndroidAutoSearchType.album,
      'Dummy',
    );
  });

  test('a media name wins over the artist for the general search', () {
    final request = siriPlayMediaRequest({
      'mediaType': 'music',
      'mediaName': 'Creep',
      'artistName': 'Radiohead',
    });
    expect(request.query, 'Creep');
    expect(request.extras, isEmpty);
  });

  test('blank and padded strings are trimmed or absent', () {
    final request = siriPlayMediaRequest({
      'mediaType': 'song',
      'mediaName': '  Hurt  ',
      'artistName': '   ',
      'albumName': '',
    });
    expect(request.query, 'Hurt');
    expect(request.extras[AndroidAutoConstants.mediaTitleKey], 'Hurt');
    expect(
      request.extras.containsKey(AndroidAutoConstants.mediaArtistKey),
      false,
    );
    expect(
      request.extras.containsKey(AndroidAutoConstants.mediaAlbumKey),
      false,
    );
  });

  test('a typed request without a name degrades to what is left', () {
    expectSearch(
      {'mediaType': 'song', 'artistName': 'Cher'},
      NavisAndroidAutoSearchType.artist,
      'Cher',
    );
  });

  test('nothing to search for is an instant-radio request', () {
    for (final args in <Map<Object?, Object?>>[
      <Object?, Object?>{},
      {'mediaType': 'music'},
      {'mediaType': 'song', 'mediaName': '  '},
    ]) {
      final request = siriPlayMediaRequest(args);
      expect(request.query, isEmpty);
      expect(request.extras, isEmpty);
      expect(parsed(args).type, NavisAndroidAutoSearchType.empty);
    }
  });
}
