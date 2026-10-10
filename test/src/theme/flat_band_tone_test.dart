import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/flat_band_tone.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

// 8-bit sRGB quantisation moves a tone by well under this.
const _eps = 0.3;

double _tone(Color c) => Hct.fromInt(c.toARGB32()).tone;

void main() {
  test('styled sample preserves coloured art and the previous grey band', () {
    const secondary = Color(0xFF456F80);
    for (final style in NavisColorStyle.values) {
      for (final dark in [false, true]) {
        final data = NavisColorStyleData(style: style, dark: dark);
        for (final sample in [Colors.grey, Colors.red, Colors.blue]) {
          final adapted = data.adaptArtColor(sample);
          final grey = Hct.fromInt(adapted.toARGB32()).chroma < 6;
          final oldSample = grey
              ? Color.lerp(sample, secondary, 0.25)!
              : sample;
          final actual = styledCoverSample(sample, data, secondary);
          expect(actual, data.adaptArtColor(oldSample));
          expect(
            flatBandSample(actual, data, adapted: true),
            flatBandSample(oldSample, data),
          );
        }
      }
    }
  });

  const light = Color(0xFFF5E6C8);
  const dark = Color(0xFF14202B);
  const yellow = Color(0xFFFFEB3B);

  for (final style in NavisColorStyle.values) {
    final night = NavisColorStyleData(style: style, dark: true);
    final day = NavisColorStyleData(style: style, dark: false);

    test('${style.name}: light cover in a dark theme is dusky', () {
      for (final cover in <Color>[light, yellow, Colors.white]) {
        expect(
          _tone(flatBandSample(cover, night)),
          lessThanOrEqualTo(30 + _eps),
        );
        final tint = captionTintFor(
          flatBandSample(cover, night),
          night,
          adapted: true,
        );
        expect(_tone(tint.fill), lessThanOrEqualTo(32));
        expect(
          captionContrast(tint.text, tint.fill),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          captionContrast(tint.subtext, tint.fill),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('${style.name}: dark cover in a light theme is soft', () {
      for (final cover in <Color>[dark, Colors.black]) {
        expect(
          _tone(flatBandSample(cover, day)),
          greaterThanOrEqualTo(82 - _eps),
        );
        final tint = captionTintFor(
          flatBandSample(cover, day),
          day,
          adapted: true,
        );
        expect(_tone(tint.fill), greaterThanOrEqualTo(78));
        expect(
          captionContrast(tint.text, tint.fill),
          greaterThanOrEqualTo(4.5),
        );
      }
    });
  }

  test('the band path adapts the style exactly once', () {
    final data = NavisColorStyleData(style: NavisColorStyle.pastel, dark: true);
    final sample = flatBandSample(const Color(0xFFFF8A65), data);
    final tint = captionTintFor(sample, data, adapted: true);
    final once = Hct.fromInt(sample.toARGB32());
    final fill = Hct.fromInt(tint.fill.toARGB32());
    // Same hue as the single-adapted sample; no second Pastel rotation.
    expect((fill.hue - once.hue).abs(), lessThan(2));
    expect(
      captionTintFor(sample, data, adapted: true),
      isNot(captionTintFor(sample, data)),
    );
  });

  test('keeps hue and caps warm chroma in dark themes', () {
    final night = NavisColorStyleData(
      style: NavisColorStyle.neutral,
      dark: true,
    );
    final out = Hct.fromInt(
      flatBandSample(const Color(0xFFFFB74D), night).toARGB32(),
    );
    expect(out.chroma, lessThanOrEqualTo(23));
    expect(
      _tone(flatBandSample(const Color(0xFF0D47A1), night)),
      greaterThanOrEqualTo(15.5),
    );
  });

  for (final style in NavisColorStyle.values) {
    test(
      '${style.name}: OLED band is tone 6-10 and captions stay readable',
      () {
        final oled = NavisColorStyleData(style: style, dark: true, oled: true);
        for (final cover in <Color>[light, yellow, Colors.white, dark]) {
          final sample = flatBandSample(cover, oled);
          expect(_tone(sample), inInclusiveRange(6 - _eps, 10 + _eps));
          final tint = captionTintFor(sample, oled, adapted: true);
          // Still near black, never the 16-30 dusk of ordinary dark.
          expect(_tone(tint.fill), lessThan(16));
          expect(
            captionContrast(tint.text, tint.fill),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            captionContrast(tint.subtext, tint.fill),
            greaterThanOrEqualTo(4.5),
          );
        }
      },
    );
  }
}
