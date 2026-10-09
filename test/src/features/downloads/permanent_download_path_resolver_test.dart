import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/downloads/data/permanent_download_path_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:navis/src/utils/file_utils.dart';

void main() {
  group('sanitizePathComponent', () {
    String clean(String? raw, {String fallback = 'fallback'}) =>
        PermanentDownloadPathResolver.sanitizePathComponent(
          raw,
          fallback: fallback,
        );

    const cases = <String?, String>{
      'Duality': 'Duality',
      'AC/DC': 'AC_DC',
      r'What? <Why>: "Now" | a\b *': 'What_ _Why__ _Now_ _ a_b _',
      'Trailing dots...': 'Trailing dots',
      'Trailing space   ': 'Trailing space',
      '   ': 'fallback',
      null: 'fallback',
      'Tab\there': 'Tab_here',
      'CON': '_CON',
      'con': '_con',
      'CON.live': '_CON.live',
      'Aux. Intro': '_Aux. Intro',
      'COM0': '_COM0',
      'LPT9': '_LPT9',
      'COM¹': '_COM¹',
      r'CONIN$': r'_CONIN$',
      r'CLOCK$': r'_CLOCK$',
      'Console': 'Console',
      'COM10': 'COM10',
      'Beyoncé': 'Beyoncé',
      'بيروت': 'بيروت',
    };
    cases.forEach((raw, expected) {
      test('${raw == null ? 'null' : '"$raw"'} becomes "$expected"', () {
        expect(clean(raw), expected);
      });
    });

    test('an unsafe fallback is cleaned too', () {
      expect(clean('', fallback: 'id:with/slashes'), 'id_with_slashes');
    });

    test('long names are capped without splitting a surrogate pair', () {
      final long = 'a' * 119 + '🎵🎵';
      final result = clean(long);
      expect(result.length, lessThanOrEqualTo(safeFileNameMaxLength));
      expect(result, 'a' * 119);
    });
  });

  group('resolvePathInDirectory', () {
    late Directory root;
    late PermanentDownloadPathResolver resolver;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('navis_resolver_');
      resolver = PermanentDownloadPathResolver(
        readCustomDownloadFolderEnabled: () => false,
        readCustomDownloadFolderPath: () => null,
      );
    });

    tearDown(() => root.delete(recursive: true));

    String resolve({Set<String> reserved = const <String>{}}) =>
        resolver.resolvePathInDirectory(
          rootDirectory: root,
          artist: 'Artist',
          title: 'Song',
          titleFallback: 'song-1',
          identity: 'song-1',
          extension: 'flac',
          reservedPaths: reserved,
        );

    for (final extension in ['x/../../evil', '../a', 'mp3\u0000', r'a\..\b']) {
      test('contains unsafe extension $extension and identity', () {
        final path = resolver.resolvePathInDirectory(
          rootDirectory: root,
          artist: '../Artist',
          title: null,
          titleFallback: '../../id/song',
          identity: '../../id/song',
          extension: extension,
        );
        expect(p.isWithin(root.path, path), isTrue);
        expect(p.extension(path), '.bin');
      });
    }

    test('throws when all 100 collision candidates are reserved', () {
      final reserved = <String>{};
      for (var i = 0; i <= 100; i++) {
        reserved.add(resolve(reserved: reserved));
      }
      expect(
        () => resolve(reserved: reserved),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('prefers the plain name and falls back to a free tagged name', () {
      final preferred = p.join(root.path, 'Artist', 'Song.flac');
      expect(resolve(), preferred);

      File(preferred)
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1]);
      final tagged = resolve();
      expect(
        p.basename(tagged),
        matches(RegExp(r'^Song \[[0-9a-f]{8}\]\.flac$')),
      );

      File(tagged).writeAsBytesSync(<int>[2]);
      final second = resolve();
      expect(
        p.basename(second),
        matches(RegExp(r'^Song \[[0-9a-f]{8}-2\]\.flac$')),
      );
      expect(resolve(reserved: <String>{second}), endsWith('-3].flac'));
    });
  });
}
