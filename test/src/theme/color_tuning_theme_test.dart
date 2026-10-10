import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  test('Light and Dark/OLED cache keys use only their resolved adjustment', () {
    final cache = NavisThemeCache();
    const seed = Color(0xFF456789);
    const tuning = ColorTuning(vividness: 2, lightDepth: -3, darkDepth: 4);
    for (final (brightness, oled) in [
      (Brightness.light, false),
      (Brightness.dark, false),
      (Brightness.dark, true),
    ]) {
      final dark = brightness == Brightness.dark;
      final theme = cache.resolve(
        seed: seed,
        style: NavisColorStyle.neutral,
        flat: false,
        corners: NavisCornerStyle.rounded,
        brightness: brightness,
        oled: oled,
        adjustment: tuning.forMode(dark: dark),
      );
      final inactiveChanged = dark
          ? const ColorTuning(vividness: 2, lightDepth: 5, darkDepth: 4)
          : const ColorTuning(vividness: 2, lightDepth: -3, darkDepth: -5);
      expect(
        cache.resolve(
          seed: seed,
          style: NavisColorStyle.neutral,
          flat: false,
          corners: NavisCornerStyle.rounded,
          brightness: brightness,
          oled: oled,
          adjustment: inactiveChanged.forMode(dark: dark),
        ),
        same(theme),
      );
      final expected = oled
          ? buildOledTheme(seed, adjustment: tuning.forMode(dark: true))
          : dark
          ? buildDarkTheme(seed, adjustment: tuning.forMode(dark: true))
          : buildLightTheme(seed, adjustment: tuning.forMode(dark: false));
      expect(theme.colorScheme, expected.colorScheme);
      if (oled) expect(theme.colorScheme.surface, const Color(0xFF000000));
    }
  });
}
