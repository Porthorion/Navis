import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/navis_tokens.dart';

void main() {
  test('square artwork has no rounding at any size', () {
    for (final extent in <double>[24, 48, 300, double.infinity]) {
      expect(artworkBorderRadius('square', extent: extent), BorderRadius.zero);
    }
  });

  test('rounded corners scale with the artwork', () {
    expect(artworkBorderRadius('rounded', extent: 32), NavisRadius.xsAll);
    expect(artworkBorderRadius('rounded', extent: 40), NavisRadius.smAll);
    expect(artworkBorderRadius('rounded', extent: 64), NavisRadius.smAll);
    expect(artworkBorderRadius('rounded', extent: 96), NavisRadius.mdAll);
    expect(
      artworkBorderRadius('rounded', extent: double.infinity),
      NavisRadius.mdAll,
    );
  });

  test('circle is fully rounded, and unknown shapes read as rounded', () {
    expect(artworkBorderRadius('circle', extent: 48), NavisRadius.pillAll);
    expect(artworkBorderRadius('blob', extent: 48), NavisRadius.smAll);
  });
}
