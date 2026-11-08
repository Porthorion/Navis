import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

NavisColorStyleData _data(double hue) => NavisColorStyleData(
  style: NavisColorStyle.immersive,
  dark: true,
  accentHue: hue,
);

double _hueAt(double a, double b, double t) =>
    _data(a).lerp(_data(b), t).accentHue;

void main() {
  group('NavisColorStyleData.lerp accent hue', () {
    test('interpolates linearly when no wrap is shorter', () {
      expect(_hueAt(100, 200, 0.5), closeTo(150, 1e-9));
      expect(_hueAt(100, 200, 0.25), closeTo(125, 1e-9));
    });

    test('takes the shortest arc across 0 in both directions', () {
      expect(_hueAt(350, 10, 0.5), closeTo(0, 1e-9));
      expect(_hueAt(350, 10, 0.25), closeTo(355, 1e-9));
      expect(_hueAt(350, 10, 0.75), closeTo(5, 1e-9));
      expect(_hueAt(10, 350, 0.5), closeTo(0, 1e-9));
      expect(_hueAt(10, 350, 0.25), closeTo(5, 1e-9));
      expect(_hueAt(10, 350, 0.75), closeTo(355, 1e-9));
    });

    test('stays inside [0, 360)', () {
      for (final (a, b) in [(350.0, 10.0), (10.0, 350.0), (359.0, 1.0)]) {
        for (var i = 1; i < 20; i++) {
          final hue = _hueAt(a, b, i / 20);
          expect(hue, inInclusiveRange(0, 360));
          expect(hue, lessThan(360));
        }
      }
    });

    test('is exact at t=0 and t=1', () {
      expect(_hueAt(350, 10, 0), 350);
      expect(_hueAt(350, 10, 1), 10);
      expect(_hueAt(123.456, 321.654, 0), 123.456);
      expect(_hueAt(123.456, 321.654, 1), 321.654);
    });

    test('keeps the discrete fields snapping at 0.5', () {
      const from = NavisColorStyleData(
        style: NavisColorStyle.pastel,
        dark: false,
        accentHue: 350,
      );
      final to = NavisColorStyleData(
        style: NavisColorStyle.immersive,
        dark: true,
        flat: true,
        flatAreas: const FlatAreas(surfaces: false),
        oled: true,
        accentHue: 10,
        adjustment: const ColorAdjustment(vividness: 3),
        controls: NavisControlColor.white,
      );

      final early = from.lerp(to, 0.49);
      expect(early.style, from.style);
      expect(early.dark, from.dark);
      expect(early.flat, from.flat);
      expect(early.flatAreas, from.flatAreas);
      expect(early.oled, from.oled);
      expect(early.adjustment, from.adjustment);
      expect(early.controls, from.controls);

      final late = from.lerp(to, 0.5);
      expect(late.style, to.style);
      expect(late.dark, to.dark);
      expect(late.flat, to.flat);
      expect(late.flatAreas, to.flatAreas);
      expect(late.oled, to.oled);
      expect(late.adjustment, to.adjustment);
      expect(late.controls, to.controls);
    });

    test('returns this for a foreign extension', () {
      final data = _data(30);
      expect(data.lerp(null, 0.7), same(data));
    });
  });
}
