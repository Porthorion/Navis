import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/cached_audio_extent.dart';

import '../../../../helpers/cached_audio_builders.dart';

// Real fixtures in test/fixtures/audio/ were made with:
//   ffmpeg -f lavfi -i "anoisesrc=d=8:r=48000:a=0.2:c=pink" -ac 1 \
//     -c:a libopus -b:a 10k -page_duration 200000 tone.opus
//   ffmpeg -f lavfi -i "anoisesrc=d=1.5:r=8000:a=0.3:c=pink" -ac 1 \
//     -sample_fmt s16 -f wav pipe:1 | flac -s -f --padding=0 \
//     --no-seektable -b 512 -o tone.flac -   (11776 samples, 1.472 s)

void main() {
  Duration seconds(num value) =>
      Duration(microseconds: (value * 1000000).round());

  Duration? extent(Uint8List bytes) => cachedAudioExtent(bytes, bytes);

  group('Ogg', () {
    Uint8List opus(List<int> granules, {int preSkip = 312}) => concat([
      opusHeadPage(preSkip: preSkip),
      for (var i = 0; i < granules.length; i++)
        oggAudioPage(granules[i], sequence: i + 1),
    ]);

    test('Opus extent is the last complete page granule minus pre-skip', () {
      final bytes = opus([48000 + 312, 48000 * 10 + 312]);
      expect(extent(bytes), seconds(10));
    });

    test('a truncated last page is ignored', () {
      final complete = opus([48000 + 312]);
      final partial = oggAudioPage(48000 * 9 + 312).sublist(0, 200);
      expect(extent(concat([complete, partial])), seconds(1));
      // Only a few bytes of the next page: still the previous one.
      expect(extent(concat([complete, 'Ogg'.codeUnits])), seconds(1));
    });

    test('a page without a granule is skipped', () {
      final bytes = concat([
        opus([48000 * 3 + 312]),
        oggAudioPage(-1, sequence: 9),
      ]);
      expect(extent(bytes), seconds(3));
    });

    test('a tail that starts inside a page still finds the last page', () {
      final bytes = opus([48000 + 312, 48000 * 2 + 312, 48000 * 4 + 312]);
      final head = bytes.sublist(0, bytes.length < 4096 ? bytes.length : 4096);
      final tail = bytes.sublist(bytes.length - 700);
      expect(cachedAudioExtent(head, tail), seconds(4));
    });

    test('OggS bytes inside a payload are not mistaken for a page', () {
      final trap = oggPage(
        [
          ...oggPage(const [1, 2, 3], granule: 48000 * 99),
          7,
          7,
          7,
        ],
        granule: 48000 * 2 + 312,
        sequence: 1,
      );
      expect(extent(concat([opusHeadPage(), trap])), seconds(2));
    });

    test('Vorbis takes the rate from the identification header', () {
      final bytes = concat([
        vorbisIdPage(rate: 22050),
        oggAudioPage(22050 * 5),
      ]);
      expect(extent(bytes), seconds(5));
    });

    test('a pre-skip longer than the granule clamps to zero', () {
      expect(extent(opus([100])), Duration.zero);
    });

    test('unknown first packet, garbage and no pages return null', () {
      expect(extent(oggPage('OggFLAC'.codeUnits, granule: 0)), isNull);
      expect(extent(Uint8List.fromList(List<int>.filled(500, 3))), isNull);
      expect(extent(Uint8List(0)), isNull);
      // Only the identification page: nothing is playable yet.
      expect(extent(opusHeadPage()), Duration.zero);
    });
  });

  group('FLAC', () {
    const rate = 44100;
    Duration frames(int number) =>
        Duration(microseconds: number * 4096 * 1000000 ~/ rate);

    test('fixed block size: last verified frame start over the rate', () {
      final bytes = concat([
        flacHead(),
        for (var n = 10; n <= 14; n++) flacFrame(n),
      ]);
      expect(extent(bytes), frames(14));
    });

    test('a fake sync with a bad CRC-8 is ignored', () {
      final bytes = concat([
        flacHead(),
        for (var n = 10; n <= 12; n++) flacFrame(n),
        flacFrame(13, badCrc: true),
      ]);
      expect(extent(bytes), frames(12));
    });

    test('a valid-CRC header that does not follow the chain is ignored', () {
      final bytes = concat([
        flacHead(),
        flacFrame(10),
        flacFrame(11),
        flacFrame(99999),
        flacFrame(12),
        flacFrame(13),
        flacFrame(500000),
      ]);
      expect(extent(bytes), frames(13));
    });

    test('a header cut off at the end is ignored', () {
      final bytes = concat([
        flacHead(),
        for (var n = 10; n <= 12; n++) flacFrame(n),
        flacFrame(13).sublist(0, 4),
      ]);
      expect(extent(bytes), frames(12));
    });

    test('variable block size uses the coded sample number', () {
      final bytes = concat([
        flacHead(minBlock: 1024, maxBlock: 4096),
        flacFrame(1000000, variable: true),
        flacFrame(1004096, variable: true),
        flacFrame(1008192, variable: true),
      ]);
      expect(extent(bytes), Duration(microseconds: 1008192 * 1000000 ~/ rate));
    });

    test('a strategy that contradicts STREAMINFO is ignored', () {
      final bytes = concat([
        flacHead(),
        flacFrame(10, variable: true),
        flacFrame(11, variable: true),
      ]);
      expect(extent(bytes), isNull);
    });

    test('explicit block size bytes extend the chain', () {
      // Code 7: a 16-bit block size minus one follows the coded number.
      final bytes = concat([
        flacHead(minBlock: 1024, maxBlock: 4096),
        flacFrame(
          0,
          variable: true,
          blockSizeCode: 7,
          blockSizeBytes: const [0x03, 0xFF],
        ),
        flacFrame(1024, variable: true),
      ]);
      expect(extent(bytes), Duration(microseconds: 1024 * 1000000 ~/ rate));
    });

    test('no STREAMINFO, or a single frame, returns null', () {
      expect(extent(concat([flacFrame(3), flacFrame(4)])), isNull);
      expect(extent(concat([flacHead(), flacFrame(3)])), isNull);
      expect(extent(flacHead()), isNull);
    });
  });

  group('real fixtures', () {
    Future<void> expectMonotonic(
      String name,
      Duration duration,
      Duration tolerance,
    ) async {
      final bytes = File('test/fixtures/audio/$name').readAsBytesSync();
      final results = <Duration>[];
      for (final fraction in [0.25, 0.5, 0.75, 1.0]) {
        final cut = bytes.sublist(0, (bytes.length * fraction).floor());
        final result = cachedAudioExtent(
          cut.sublist(0, cut.length < 4096 ? cut.length : 4096),
          cut.sublist(cut.length < 131072 ? 0 : cut.length - 131072),
        );
        expect(result, isNotNull, reason: '$name at $fraction');
        results.add(result!);
      }
      for (var i = 0; i < results.length; i++) {
        expect(results[i], greaterThanOrEqualTo(Duration.zero));
        expect(results[i], lessThanOrEqualTo(duration));
        if (i > 0) expect(results[i], greaterThanOrEqualTo(results[i - 1]));
      }
      expect(duration - results.last, lessThanOrEqualTo(tolerance));
    }

    test('Opus truncated at 25/50/75/100 percent', () async {
      await expectMonotonic(
        'tone.opus',
        const Duration(seconds: 8),
        const Duration(milliseconds: 250),
      );
    });

    test('FLAC truncated at 25/50/75/100 percent', () async {
      await expectMonotonic(
        'tone.flac',
        const Duration(milliseconds: 1472),
        const Duration(milliseconds: 80),
      );
    });
  });

  group('readCachedAudioExtent', () {
    late Directory directory;
    setUp(() => directory = Directory.systemTemp.createTempSync('navis-ext-'));
    tearDown(() => directory.deleteSync(recursive: true));

    test('reads a file and never throws for a missing one', () async {
      final file = File('${directory.path}/a.part')
        ..writeAsBytesSync(
          concat([opusHeadPage(), oggAudioPage(48000 * 7 + 312)]),
        );
      expect(await readCachedAudioExtent(file.path), seconds(7));
      expect(await readCachedAudioExtent('${directory.path}/none'), isNull);
      expect(await readCachedAudioExtent(directory.path), isNull);
    });

    test('reads only the head and the tail of a large file', () async {
      // 4 x 40 kB pages: larger than the 128 kB tail window.
      final pages = <List<int>>[
        opusHeadPage(),
        for (var i = 0; i < 4; i++)
          oggAudioPage(48000 * (i + 1) + 312, size: 40000),
      ];
      final file = File('${directory.path}/big.part')
        ..writeAsBytesSync(concat(pages));
      expect(await readCachedAudioExtent(file.path), seconds(4));
    });
  });
}
