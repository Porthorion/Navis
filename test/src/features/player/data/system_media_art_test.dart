import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/system_media_art.dart';
import 'package:navis/src/utils/credential_redaction.dart';
import 'package:path/path.dart' as p;

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

  group('typedSystemArtFile', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('navis_art_'));
    tearDown(() => dir.deleteSync(recursive: true));

    String cover(List<int> bytes) {
      final file = File(p.join(dir.path, 'navis_art_c.jpg'))
        ..writeAsBytesSync(bytes);
      return file.path;
    }

    test('keeps a JPEG cover where it is', () {
      final path = cover(const [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10]);
      expect(typedSystemArtFile(path), path);
      expect(dir.listSync(), hasLength(1));
    });

    test('names a PNG cover for its type', () {
      const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2];
      final typed = typedSystemArtFile(cover(png));
      expect(typed, p.join(dir.path, 'navis_art_c.png'));
      expect(File(typed).readAsBytesSync(), png);
    });

    test('names WebP and GIF covers for their types', () {
      expect(
        p.extension(
          typedSystemArtFile(
            cover(const [
              0x52,
              0x49,
              0x46,
              0x46,
              0,
              0,
              0,
              0,
              0x57,
              0x45,
              0x42,
              0x50,
            ]),
          ),
        ),
        '.webp',
      );
      expect(
        p.extension(
          typedSystemArtFile(cover(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])),
        ),
        '.gif',
      );
    });

    test('keeps unknown or missing files as they are', () {
      final unknown = cover(const [1, 2, 3, 4]);
      expect(typedSystemArtFile(unknown), unknown);
      final missing = p.join(dir.path, 'missing.jpg');
      expect(typedSystemArtFile(missing), missing);
    });
  });
}
