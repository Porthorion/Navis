import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/semver.dart';

void main() {
  test('release parsing shares tag, build and label handling', () {
    expect(parseSemver(' v1.4.3-sidecar+10403 '), [1, 4, 3]);
    expect(parseSemver('1.4'), isNull);
    expect(parseSemver('1.4.x'), isNull);
    expect(parseSemver('1.4.3.4'), isNull);
    expect(parseSemver('1.4.3.4', allowExtraParts: true), [1, 4, 3]);
    expect(compareSemver([1, 4, 10], [1, 4, 3]), greaterThan(0));
    expect(compareSemver([1, 4, 3], [1, 4, 3]), 0);
  });
}
