import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/downloads/data/download_path_identity.dart';
import 'package:path/path.dart' as p;

void main() {
  group('on Windows', () {
    final identity = DownloadRootIdentity.of(
      r'D:\Music',
      canonicalRoot: r'\\nas\share\Music',
      context: p.windows,
    );

    test('keys use forward slashes whichever spelling reached the file', () {
      expect(identity.keyFor(r'D:\Music\Artist\Song.flac'), 'Artist/Song.flac');
      expect(
        identity.keyFor(r'\\nas\share\Music\Artist\Song.flac'),
        'Artist/Song.flac',
      );
      expect(identity.keyFor(r'd:\music\Artist\Song.flac'), 'Artist/Song.flac');
    });

    test('lookups ignore case and read older backslash keys', () {
      expect(
        identity.lookupKey(r'artist\SONG.flac'),
        identity.lookupKey('Artist/Song.flac'),
      );
    });

    test('files outside the folder have no key', () {
      expect(identity.keyFor(r'D:\Other\Song.flac'), isNull);
      expect(identity.keyFor(r'D:\Music'), isNull);
    });

    test('keys map back into the resolved folder', () {
      expect(
        identity.pathFor('Artist/Song.flac'),
        r'\\nas\share\Music\Artist\Song.flac',
      );
    });
  });

  group('on POSIX', () {
    final identity = DownloadRootIdentity.of(
      '/home/me/Music',
      canonicalRoot: '/mnt/data/Music',
      context: p.posix,
    );

    test('case matters and both spellings map to one key', () {
      expect(identity.keyFor('/mnt/data/Music/A/b.flac'), 'A/b.flac');
      expect(identity.keyFor('/home/me/Music/A/b.flac'), 'A/b.flac');
      expect(
        identity.lookupKey('A/B.flac'),
        isNot(identity.lookupKey('A/b.flac')),
      );
    });
  });

  test('resolve follows a symlinked folder', () async {
    final sandbox = await Directory.systemTemp.createTemp('navis_identity_');
    addTearDown(() => sandbox.delete(recursive: true));
    final real = Directory('${sandbox.path}/real')..createSync();
    final link = Link('${sandbox.path}/link')..createSync(real.path);

    final identity = await DownloadRootIdentity.resolve(link.path);

    expect(identity.canonicalRoot, real.resolveSymbolicLinksSync());
    expect(identity.keyFor('${link.path}/a.flac'), 'a.flac');
    expect(identity.keyFor('${real.path}/a.flac'), 'a.flac');
  }, skip: Platform.isWindows);
}
