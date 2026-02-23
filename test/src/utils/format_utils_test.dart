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
}
