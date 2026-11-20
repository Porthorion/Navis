import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/constants.dart';

void main() {
  test('no define leaves the bundled Last.fm key empty', () {
    expect(AppConstants.lastFmApiKey, isEmpty);
  });
}
