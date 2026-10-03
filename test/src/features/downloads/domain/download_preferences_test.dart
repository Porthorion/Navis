import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';

void main() {
  group('DownloadQualityPreference', () {
    test('unknown stored values fall back to defaults', () {
      final preference = DownloadQualityPreference.fromStored(
        mode: 'bogus',
        bitRate: 999,
        format: 'wma',
      );
      expect(preference.mode, DownloadQualityMode.ask);
      expect(preference.bitRate, 320);
      expect(preference.format, 'mp3');
      expect(preference.prompted, isFalse);
      expect(preference.savedChoice, isNull);
    });

    test('a saved mode returns an automatic choice', () {
      final original = DownloadQualityPreference.fromStored(mode: 'original');
      expect(original.savedChoice?.isOriginal, isTrue);
      expect(original.savedChoice?.automatic, isTrue);

      final transcode = DownloadQualityPreference.fromStored(
        mode: 'transcode',
        bitRate: 192,
        format: 'OPUS',
      );
      final choice = transcode.savedChoice!;
      expect(choice.quality, '192');
      expect(choice.format, 'opus');
      expect(choice.automatic, isTrue);
    });

    test('fromChoice maps a picked quality to a saved mode', () {
      expect(
        DownloadQualityPreference.fromChoice(const DownloadQualityChoice())
            .mode,
        DownloadQualityMode.original,
      );
      final saved = DownloadQualityPreference.fromChoice(
        const DownloadQualityChoice(quality: '256', format: 'AAC'),
      );
      expect(saved.mode, DownloadQualityMode.transcode);
      expect(saved.bitRate, 256);
      expect(saved.format, 'aac');
    });

    test('concurrency is clamped to 1..4', () {
      expect(sanitizeConcurrentDownloads(null), kDefaultConcurrentDownloads);
      expect(sanitizeConcurrentDownloads(0), 1);
      expect(sanitizeConcurrentDownloads(3), 3);
      expect(sanitizeConcurrentDownloads(64), kMaxConcurrentDownloads);
    });
  });

  group('download quality identity', () {
    test('an AAC download stored as m4a is the same format', () {
      expect(sameAudioFormat('m4a', 'aac'), isTrue);
      expect(sameAudioFormat('.MP3', 'mp3'), isTrue);
      expect(sameAudioFormat('opus', 'mp3'), isFalse);
      expect(
        const DownloadQualityChoice(
          quality: '256',
          format: 'aac',
        ).sameQualityAs(
          const DownloadQualityChoice(quality: '256', format: 'm4a'),
        ),
        isTrue,
      );
    });

    test('an original download records the song bitrate yet is original', () {
      expect(
        isOriginalQualityDownload(
          format: 'flac',
          bitRate: 1411,
          songSuffix: 'flac',
          songBitRate: 1411,
        ),
        isTrue,
      );
      expect(isOriginalQualityDownload(format: 'flac', bitRate: null), isTrue);
      // A transcode of a FLAC song is not original.
      expect(
        isOriginalQualityDownload(
          format: 'mp3',
          bitRate: 320,
          songSuffix: 'flac',
          songBitRate: 1411,
        ),
        isFalse,
      );
      // Without the song's format, a recorded bitrate cannot be trusted.
      expect(isOriginalQualityDownload(format: 'mp3', bitRate: 320), isFalse);
    });
  });

  group('downloaded format', () {
    test('keeps the requested format when the server agrees', () {
      expect(
        downloadedFormatFor(requested: 'mp3', contentType: 'audio/mpeg'),
        'mp3',
      );
      expect(
        downloadedFormatFor(requested: 'opus', contentType: 'audio/ogg'),
        'opus',
      );
      expect(downloadedFormatFor(requested: 'mp3', contentType: null), 'mp3');
      expect(
        downloadedFormatFor(
          requested: 'mp3',
          contentType: 'application/octet-stream',
        ),
        'mp3',
      );
    });

    test('names what the server actually sent', () {
      expect(
        downloadedFormatFor(requested: 'opus', contentType: 'audio/flac'),
        'flac',
      );
      expect(
        downloadedFormatFor(
          requested: 'aac',
          contentType: 'audio/mp4; codecs=mp4a',
        ),
        'm4a',
      );
    });

    test('error documents are not audio', () {
      expect(isNonAudioContentType('text/xml; charset=utf-8'), isTrue);
      expect(isNonAudioContentType('application/json'), isTrue);
      expect(isNonAudioContentType('audio/mpeg'), isFalse);
      expect(isNonAudioContentType('application/octet-stream'), isFalse);
      expect(isNonAudioContentType(null), isFalse);
    });
  });
}
