import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/format_utils.dart';

void main() {
  group('formatBytes', () {
    test('formats zero bytes', () {
      expect(formatBytes(0), '0 B');
    });

    test('formats bytes < 1 KB', () {
      expect(formatBytes(512), '512 B');
    });

    test('formats kilobytes', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
    });

    test('formats megabytes', () {
      expect(formatBytes(1048576), '1.0 MB');
      expect(formatBytes(2621440), '2.5 MB');
    });

    test('formats gigabytes', () {
      expect(formatBytes(1073741824), '1.00 GB');
      expect(formatBytes(2684354560), '2.50 GB');
    });
  });

  group('formatPlaybackSpeed', () {
    test('formats whole number speeds without decimals', () {
      expect(formatPlaybackSpeed(1), '1×');
      expect(formatPlaybackSpeed(2), '2×');
    });

    test('formats fractional speeds without unnecessary trailing zeroes', () {
      expect(formatPlaybackSpeed(1.5), '1.5×');
      expect(formatPlaybackSpeed(1.25), '1.25×');
      expect(formatPlaybackSpeed(0.75), '0.75×');
    });
  });

  group('formatDuration', () {
    test('formats sub-hour durations as minutes and seconds', () {
      expect(formatDuration(const Duration(seconds: 5)), '0:05');
      expect(formatDuration(const Duration(minutes: 3, seconds: 7)), '3:07');
    });

    test('formats hour durations as total minutes by default', () {
      expect(
        formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '62:03',
      );
    });

    test('formats hour durations with a padded minute and second field', () {
      expect(
        formatDuration(
          const Duration(hours: 1, minutes: 2, seconds: 3),
          showHours: true,
        ),
        '1:02:03',
      );
    });
  });

  group('formatSeconds', () {
    test('formats positive second counts', () {
      expect(formatSeconds(67), '1:07');
    });

    test('uses the fallback for null and non-positive values', () {
      expect(formatSeconds(null), '--:--');
      expect(formatSeconds(0), '--:--');
      expect(formatSeconds(-4, fallback: ''), '');
    });
  });
}
