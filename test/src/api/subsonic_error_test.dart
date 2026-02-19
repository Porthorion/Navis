import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_error.dart';

void main() {
  test('maps known Subsonic error codes to typed exceptions', () {
    expect(
      mapSubsonicApiError(code: 40, message: 'auth failed'),
      isA<SubsonicAuthException>(),
    );
    expect(
      mapSubsonicApiError(code: 50, message: 'forbidden'),
      isA<SubsonicForbiddenException>(),
    );
    expect(
      mapSubsonicApiError(code: 70, message: 'missing'),
      isA<SubsonicNotFoundException>(),
    );
    expect(
      mapSubsonicApiError(code: 999, message: 'other'),
      isA<SubsonicGenericException>(),
    );
  });
}
