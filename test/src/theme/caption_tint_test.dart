import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

void main() {
  const palette = <String, Color>{
    'white': Color(0xFFFFFFFF),
    'black': Color(0xFF000000),
    'yellow': Color(0xFFFFEB3B),
    'mid grey': Color(0xFF777777),
    'mid grey light': Color(0xFF8A8A8A),
    'saturated red': Color(0xFFE53935),
    'pastel pink': Color(0xFFF8BBD0),
    'teal': Color(0xFF008080),
    'blue': Color(0xFF3355FF),
  };

  for (final style in NavisColorStyle.values) {
    for (final dark in <bool>[false, true]) {
      final data = NavisColorStyleData(style: style, dark: dark);
      for (final entry in palette.entries) {
        test('${entry.key} reads at 4.5:1 in ${style.name} '
            '${dark ? 'dark' : 'light'}', () {
          final tint = captionTintFor(entry.value, data);
          expect(tint.fill.a, 1);
          expect(
            captionContrast(tint.text, tint.fill),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            captionContrast(tint.subtext, tint.fill),
            greaterThanOrEqualTo(4.5),
          );
        });
      }
    }
  }

  test('a colour that already reads is kept as the fill (Neutral)', () {
    const data = NavisColorStyleData.neutralDark;
    final tint = captionTintFor(const Color(0xFF202840), data);
    expect(tint.fill, const Color(0xFF202840));
    expect(tint.text, Colors.white);
  });

  test('light covers get dark ink, dark covers white text', () {
    const data = NavisColorStyleData.neutralDark;
    expect(
      captionTintFor(const Color(0xFFFFFFFF), data).text,
      isNot(Colors.white),
    );
    expect(captionTintFor(const Color(0xFF000000), data).text, Colors.white);
  });

  test('a mid-tone cover is darkened or lightened, hue kept roughly', () {
    const data = NavisColorStyleData.neutralDark;
    const sampled = Color(0xFFE53935);
    final tint = captionTintFor(sampled, data);
    expect(tint.fill, isNot(sampled));
    expect(captionContrast(tint.text, tint.fill), greaterThanOrEqualTo(4.5));
  });
}
