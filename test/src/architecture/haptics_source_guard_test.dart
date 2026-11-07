import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every haptic goes through `NavisHaptics` so Settings -> Haptics can gate it.
/// `AdjustmentRuler` keeps its own tuned primitives, but checks
/// `NavisHaptics.allows` first.
final _raw = RegExp(r'\bHapticFeedback\.');
const _allowed = {
  'lib/src/common_widgets/navis_haptics.dart',
  'lib/src/features/player/presentation/adjustment_ruler.dart',
};

void main() {
  test('lib plays haptics only through NavisHaptics', () {
    final violations = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (f) => f.path.endsWith('.dart') && !_allowed.contains(f.path),
            )) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_raw.hasMatch(lines[i])) {
          violations.add('${file.path}:${i + 1} calls HapticFeedback');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('the ruler checks the gate before its raw haptics', () {
    final source = File(
      'lib/src/features/player/presentation/adjustment_ruler.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('NavisHaptics.allows(HapticCategory.slidersAndRulers)'),
    );
    expect(
      source,
      contains('NavisHaptics.allows(HapticCategory.switchesAndSteppers)'),
    );
  });
}
