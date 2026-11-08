import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:navis/src/utils/app_logger.dart';

void main() {
  final forwarded = <String>[];

  setUp(() {
    forwarded.clear();
    AppLogger.debugWarningSink = forwarded.add;
  });

  tearDown(() {
    AppLogger.debugWarningSink = null;
  });

  test('package warnings reach AppLogger', () {
    AppLogger.forwardPackageLogging();

    Logger('X').warning('boom');

    expect(forwarded, ['X: boom']);
  });

  test('info records are not forwarded', () {
    AppLogger.forwardPackageLogging();

    Logger('X').info('quiet');

    expect(forwarded, isEmpty);
  });

  test('forwarding twice forwards one warning once', () {
    AppLogger.forwardPackageLogging();
    AppLogger.forwardPackageLogging();

    Logger('X').warning('boom');

    expect(forwarded, ['X: boom']);
  });
}
