import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

void main() {
  test('complete themes reuse all inputs and evict the least recent entry', () {
    final cache = NavisThemeCache(capacity: 2);
    ThemeData resolve({
      Color seed = Colors.white,
      Brightness brightness = Brightness.dark,
      bool oled = false,
      NavisColorStyle style = NavisColorStyle.neutral,
      bool flat = false,
      NavisCornerStyle corners = NavisCornerStyle.rounded,
      ColorAdjustment adjustment = ColorAdjustment.none,
    }) => cache.resolve(
      seed: seed,
      brightness: brightness,
      oled: oled,
      style: style,
      flat: flat,
      corners: corners,
      adjustment: adjustment,
    );
    final dark = resolve();
    expect(resolve(), same(dark));
    final light = resolve(brightness: Brightness.light);
    expect(light.colorScheme, buildLightTheme(Colors.white).colorScheme);
    expect(resolve(), same(dark));
    final oled = resolve(oled: true);
    expect(oled.colorScheme, buildOledTheme(Colors.white).colorScheme);
    expect(resolve(), same(dark));
    expect(resolve(brightness: Brightness.light), isNot(same(light)));
    final flat = resolve(flat: true);
    expect(flat.shadowColor, Colors.transparent);
    final square = resolve(corners: NavisCornerStyle.square);
    expect(
      square.extension<NavisShapeData>()!.xl,
      NavisShapeData.forStyle(NavisCornerStyle.square).xl,
    );
    final styled = resolve(style: NavisColorStyle.night);
    expect(
      styled.colorScheme,
      buildDarkTheme(Colors.white, style: NavisColorStyle.night).colorScheme,
    );
    const adj = ColorAdjustment(vividness: 3, depth: -2);
    final tuned = resolve(adjustment: adj);
    expect(tuned.extension<NavisColorStyleData>()!.adjustment, adj);
    expect(
      resolve(adjustment: const ColorAdjustment(vividness: 3, depth: -2)),
      same(tuned),
    );
    expect(
      resolve(adjustment: const ColorAdjustment(vividness: 2, depth: -2)),
      isNot(same(tuned)),
    );
    expect(
      resolve(adjustment: const ColorAdjustment(vividness: 3, depth: -1)),
      isNot(same(tuned)),
    );
    final seeded = resolve(seed: Colors.blue);
    expect(seeded.colorScheme, buildDarkTheme(Colors.blue).colorScheme);
  });
}
