import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Home imports the Integrations feature (its Deezer sections, the notice
/// card), so Integrations must not import Home: that would be a
/// feature-to-feature cycle. Anything Integrations needs from Home goes
/// through the composition root (`lib/src/providers/app_providers.dart`),
/// such as `refreshWeeklyPlaylistsAfterTokenValidationProvider`.
void main() {
  test('the Integrations feature never imports the Home feature', () {
    final violations = <String>[];
    final files = Directory('lib/src/features/integrations')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    final homeImport = RegExp(
      r'''^\s*(import|export)\s+['"](package:navis/src/features/home/|(\.\./)+home/)''',
      multiLine: true,
    );
    for (final file in files) {
      if (homeImport.hasMatch(file.readAsStringSync())) {
        violations.add(file.path);
      }
    }
    expect(violations, isEmpty, reason: 'Integrations files importing Home');
  });
}
