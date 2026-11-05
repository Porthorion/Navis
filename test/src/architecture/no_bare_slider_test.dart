import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Material's `Slider` always wraps its value indicator in an `OverlayPortal`.
/// In a pushed route that sends the engine an orphan semantics node, which
/// freezes the macOS/Windows accessibility tree (flutter/flutter#190357), so
/// every slider goes through `NavisSlider`.
final _bareSlider = RegExp(r'(?<![A-Za-z0-9_.])(Range)?Slider(\.adaptive)?\(');

void main() {
  test('lib builds sliders only through NavisSlider', () {
    final violations = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) =>
              file.path.endsWith('.dart') &&
              !file.path.endsWith('common_widgets/navis_slider.dart'),
        );
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_bareSlider.hasMatch(lines[i])) {
          violations.add('${file.path}:${i + 1} builds a bare Slider');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('the scan recognises a bare Slider and ignores NavisSlider', () {
    expect(_bareSlider.hasMatch('child: Slider('), isTrue);
    expect(_bareSlider.hasMatch('return Slider.adaptive('), isTrue);
    expect(_bareSlider.hasMatch('child: NavisSlider('), isFalse);
    expect(_bareSlider.hasMatch('SliderTheme.of(context)'), isFalse);
  });
}
