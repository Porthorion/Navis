import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  group('Flat', () {
    test('every builder records flat in the colour style extension', () {
      for (final style in NavisColorStyle.values) {
        final builders = <ThemeData Function({required bool flat})>[
          ({required flat}) => buildLightTheme(
            const Color(0xFF009688),
            style: style,
            flat: flat,
          ),
          ({required flat}) =>
              buildDarkTheme(const Color(0xFF009688), style: style, flat: flat),
          ({required flat}) =>
              buildOledTheme(const Color(0xFF009688), style: style, flat: flat),
        ];
        for (final build in builders) {
          expect(
            build(flat: true).extension<NavisColorStyleData>()!.flat,
            isTrue,
          );
          expect(
            build(flat: false).extension<NavisColorStyleData>()!.flat,
            isFalse,
          );
        }
      }
    });

    test('defaults to off and survives copyWith', () {
      expect(
        buildDarkTheme(const Color(0xFF009688))
            .extension<NavisColorStyleData>()!
            .flat,
        isFalse,
      );
      expect(NavisColorStyleData.neutralDark.flat, isFalse);
      expect(NavisColorStyleData.neutralDark.copyWith(flat: true).flat, isTrue);
      expect(
        NavisColorStyleData.neutralDark
            .copyWith(flat: true)
            .copyWith(dark: false)
            .flat,
        isTrue,
      );
    });

    test('removes theme-level shadows only when on', () {
      final flat = buildLightTheme(const Color(0xFF009688), flat: true);
      final depth = buildLightTheme(const Color(0xFF009688));
      expect(flat.shadowColor, Colors.transparent);
      expect(flat.colorScheme.shadow, Colors.transparent);
      expect(depth.colorScheme.shadow, isNot(Colors.transparent));
      expect(
        buildOledTheme(
          const Color(0xFF009688),
          flat: true,
        ).dialogTheme.shadowColor,
        Colors.transparent,
      );
    });
  });

  group('NavisAccentColors', () {
    const vividAccent = Color(0xFF009688);
    const dynamicAccent = Color(0xFF008577);

    test('keeps a vivid selected color exact in light and dark themes', () {
      final lightAccent = buildLightTheme(vividAccent)
          .extension<NavisAccentColors>()!;
      final darkAccent = buildDarkTheme(vividAccent)
          .extension<NavisAccentColors>()!;

      expect(lightAccent.source, vividAccent);
      expect(lightAccent.brand, vividAccent);
      expect(darkAccent.source, vividAccent);
      expect(darkAccent.brand, vividAccent);
    });

    test('falls back from white in light mode when contrast is unsafe', () {
      final theme = buildLightTheme(defaultColorSchemeSeedColor);
      final accent = theme.extension<NavisAccentColors>()!;

      expect(accent.source, defaultColorSchemeSeedColor);
      expect(accent.brand, isNot(defaultColorSchemeSeedColor));
      expect(
        _contrastRatio(accent.brand, theme.colorScheme.surface),
        greaterThanOrEqualTo(3.0),
      );
    });

    test('keeps light-theme text and titles readable on the surface', () {
      final scheme = buildLightTheme(defaultColorSchemeSeedColor).colorScheme;

      expect(
        _contrastRatio(scheme.onSurface, scheme.surface),
        greaterThan(4.5),
      );
      expect(
        _contrastRatio(scheme.onSurfaceVariant, scheme.surface),
        greaterThan(4.5),
      );
      expect(_contrastRatio(scheme.primary, scheme.surface), greaterThan(4.5));
    });

    test('keeps white exact in dark and OLED themes when contrast is safe', () {
      final darkAccent = buildDarkTheme(defaultColorSchemeSeedColor)
          .extension<NavisAccentColors>()!;
      final oledAccent = buildOledTheme(defaultColorSchemeSeedColor)
          .extension<NavisAccentColors>()!;

      expect(darkAccent.brand, defaultColorSchemeSeedColor);
      expect(oledAccent.brand, defaultColorSchemeSeedColor);
    });

    test('uses the effective dynamic seed as the brand source', () {
      final selectedTheme = buildLightTheme(vividAccent);
      final dynamicTheme = buildLightTheme(dynamicAccent);

      final selectedAccent = selectedTheme.extension<NavisAccentColors>()!;
      final dynamicResolvedAccent = dynamicTheme
          .extension<NavisAccentColors>()!;

      expect(selectedAccent.source, vividAccent);
      expect(dynamicResolvedAccent.source, dynamicAccent);
      expect(dynamicResolvedAccent.source, isNot(selectedAccent.source));
      expect(dynamicResolvedAccent.brand, dynamicAccent);
    });
  });
}

double _contrastRatio(Color a, Color b) {
  final aLuminance = a.computeLuminance();
  final bLuminance = b.computeLuminance();
  final lighter = aLuminance > bLuminance ? aLuminance : bLuminance;
  final darker = aLuminance > bLuminance ? bLuminance : aLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
