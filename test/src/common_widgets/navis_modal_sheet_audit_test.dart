import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every sheet opens through showNavisModalSheet', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      if (file.path.endsWith('common_widgets/navis_modal_sheet.dart')) continue;
      if (RegExp(r'\bshowModalBottomSheet\b')
          .hasMatch(file.readAsStringSync())) {
        offenders.add(file.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'raw showModalBottomSheet skips the Album Color fill',
    );
  });
}
