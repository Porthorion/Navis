import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/presentation/audio_quality_format.dart';

void main() {
  group('readSampleRateFromExtras', () {
    test('null and empty extras have no rate', () {
      expect(readSampleRateFromExtras(null), isNull);
      expect(readSampleRateFromExtras(const {}), isNull);
      expect(readSampleRateFromExtras(const {'bitRate': 320}), isNull);
    });

    test('reads ints, rounds doubles and parses strings', () {
      expect(readSampleRateFromExtras(const {'sampleRate': 44100}), 44100);
      expect(readSampleRateFromExtras(const {'sampleRate': 44100.6}), 44101);
      expect(readSampleRateFromExtras(const {'sampleRate': ' 48000 '}), 48000);
      expect(readSampleRateFromExtras(const {'sampleRate': '44100.4'}), 44100);
    });

    test('an int or double that is not positive ends the search', () {
      expect(
        readSampleRateFromExtras(const {
          'resolvedSampleRate': 0,
          'sampleRate': 44100,
        }),
        isNull,
      );
      expect(readSampleRateFromExtras(const {'sampleRate': -5.0}), isNull);
      expect(readSampleRateFromExtras(const {'sampleRate': 0.2}), isNull);
    });

    test('unusable strings fall through to the next key', () {
      expect(
        readSampleRateFromExtras(const {
          'resolvedSampleRate': 'n/a',
          'sampleRate': '0',
          'samplingRate': '0.3',
          'sample_rate': null,
          'sampling_rate': '96000',
        }),
        96000,
      );
      expect(readSampleRateFromExtras(const {'sampleRate': 'x'}), isNull);
    });

    test('earlier keys win', () {
      expect(
        readSampleRateFromExtras(const {
          'sampling_rate': 22050,
          'resolvedSampleRate': 88200,
        }),
        88200,
      );
    });
  });

  group('audioFormatLabel', () {
    test('upper-cases a format and hides transcoded or blank ones', () {
      expect(audioFormatLabel(' flac '), 'FLAC');
      expect(audioFormatLabel('Transcoded'), isNull);
      expect(audioFormatLabel('  '), isNull);
      expect(audioFormatLabel(null), isNull);
    });
  });

  group('inferAudioFormat', () {
    test('uses the content-type subtype', () {
      expect(inferAudioFormat('audio/flac'), 'FLAC');
      expect(inferAudioFormat('audio/mpeg'), 'MPEG');
    });

    test('rejects values without a usable subtype', () {
      expect(inferAudioFormat(null), isNull);
      expect(inferAudioFormat('flac'), isNull);
      expect(inferAudioFormat('audio/ '), isNull);
    });
  });

  group('formatBitRate', () {
    test('stays in Kb/s below 1024', () {
      expect(formatBitRate(320), '320 Kb/s');
      expect(formatBitRate(1023), '1023 Kb/s');
    });

    test('switches to Mb/s with one decimal only when needed', () {
      expect(formatBitRate(1024), '1 Mb/s');
      expect(formatBitRate(2048), '2 Mb/s');
      expect(formatBitRate(1536), '1.5 Mb/s');
    });
  });

  group('formatSampleRate', () {
    test('drops the decimal for whole kHz', () {
      expect(formatSampleRate(48000), '48 kHz');
      expect(formatSampleRate(96000), '96 kHz');
    });

    test('keeps one decimal otherwise', () {
      expect(formatSampleRate(44100), '44.1 kHz');
      expect(formatSampleRate(22050), '22.1 kHz');
    });
  });
}
