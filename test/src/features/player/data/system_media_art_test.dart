import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/system_media_art.dart';
import 'package:navis/src/utils/credential_redaction.dart';

void main() {
  final coverUrl = Uri.parse(
    'https://music.test/rest/getCoverArt.view?id=c1&u=me&t=tok&s=salt&size=512',
  );

  test('publishes the cached cover file, never the cover URL', () {
    expect(
      systemArtUrl(MediaItem(id: 's', title: 't', artUri: coverUrl)),
      isNull,
    );
    expect(
      systemArtUrl(
        MediaItem(
          id: 's',
          title: 't',
          artUri: coverUrl,
          extras: const <String, Object?>{
            artCacheFileExtra: '/tmp/navis_art_c1.jpg',
          },
        ),
      ),
      'file:///tmp/navis_art_c1.jpg',
    );
  });

  test('keeps artwork URLs without credentials, such as radio art', () {
    expect(
      systemArtUrl(
        MediaItem(
          id: 'radio',
          title: 'Station',
          artUri: Uri.parse('https://radio.test/art.jpg?size=300'),
        ),
      ),
      'https://radio.test/art.jpg?size=300',
    );
  });

  test('detects every credential parameter, case-insensitively', () {
    for (final key in <String>['u', 't', 's', 'p', 'apiKey', 'APIKEY']) {
      expect(
        uriCarriesCredentials(Uri.parse('https://h.test/x?id=1&$key=v')),
        isTrue,
        reason: key,
      );
    }
    expect(uriCarriesCredentials(Uri.parse('https://h.test/x?id=1')), isFalse);
  });
}
