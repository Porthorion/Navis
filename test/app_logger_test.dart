import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/app_logger.dart';

void main() {
  group('AppLogger', () {
    test('info logs without throwing', () {
      expect(() => AppLogger.info('info message'), returnsNormally);
    });

    test('warning logs without throwing', () {
      expect(() => AppLogger.warning('warning message'), returnsNormally);
    });

    test('error logs without throwing', () {
      expect(
        () => AppLogger.error(
          'error message',
          Exception('boom'),
          StackTrace.current,
        ),
        returnsNormally,
      );
    });
  });
}
