import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

void main() {
  for (final style in NavisColorStyle.values) {
    for (final mode in ['light', 'dark', 'oled']) {
      test('$style $mode solid, tonal and white control contracts', () {
        for (final seed in [
          Colors.white,
          Colors.grey,
          Colors.yellow,
          Colors.orange,
          Colors.red,
          Colors.pink,
          Colors.blue,
          Colors.green,
          Colors.brown,
          const Color(0xFFFF1493),
          const Color(0xFF0A1F5C),
        ]) {
          for (final controls in NavisControlColor.values) {
            for (final tint in [0, 3, 5]) {
              final adj = ColorAdjustment(tint: tint, controls: controls);
              final theme = switch (mode) {
                'light' => buildLightTheme(seed, style: style, adjustment: adj),
                'dark' => buildDarkTheme(seed, style: style, adjustment: adj),
                _ => buildOledTheme(seed, style: style, adjustment: adj),
              };
              final scheme = theme.colorScheme;
              final data = theme.extension<NavisColorStyleData>()!;
              expect(data.controls, controls);
              expect(data.solidPlayButton, isTrue);
              expect(
                _contrast(
                  data.onPlayButtonFill(scheme),
                  data.playButtonFill(scheme),
                ),
                greaterThanOrEqualTo(4.5),
              );
              expect(
                _contrast(
                  data.onTonalControlFill(scheme),
                  data.tonalControlFill(scheme),
                ),
                greaterThanOrEqualTo(4.5),
              );
              if (controls == NavisControlColor.accent) {
                expect(data.playButtonFill(scheme), scheme.primary);
                expect(data.onPlayButtonFill(scheme), scheme.onPrimary);
                expect(
                  data.tonalControlFill(scheme),
                  scheme.secondaryContainer,
                );
                expect(
                  data.onTonalControlFill(scheme),
                  scheme.onSecondaryContainer,
                );
                expect(data.controlEdge, isNull);
                expect(theme.sliderTheme.activeTrackColor, isNull);
              } else {
                expect(data.playButtonFill(scheme), Colors.white);
                expect(data.tonalControlFill(scheme), isNot(Colors.white));
                expect(data.controlEdge == null, mode != 'light');
                if (mode == 'light') {
                  expect(data.controlEdge!.a, closeTo(0.25, 0.01));
                }
                expect(
                  theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
                  Colors.white,
                );
                expect(
                  theme.filledButtonTheme.style!.foregroundColor!.resolve({}),
                  data.onPlayButtonFill(scheme),
                );
                expect(theme.sliderTheme.activeTrackColor, Colors.white);
                expect(theme.sliderTheme.thumbColor, Colors.white);
                expect(
                  theme.sliderTheme.inactiveTrackColor,
                  scheme.surfaceContainerHighest,
                );
                expect(
                  theme.sliderTheme.thumbShape!.getPreferredSize(true, false),
                  const Size(20, 20),
                );
                expect(
                  theme.switchTheme.thumbColor!.resolve({WidgetState.selected}),
                  Colors.white,
                );
                expect(
                  theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
                  scheme.primary,
                );
                expect(
                  theme.navigationBarTheme.indicatorColor,
                  data.tonalControlFill(scheme),
                );
                expect(
                  theme.navigationBarTheme.iconTheme!.resolve({
                    WidgetState.selected,
                  })!.color,
                  data.onTonalControlFill(scheme),
                );
                expect(
                  theme.navigationBarTheme.iconTheme!.resolve({})!.color,
                  scheme.onSurfaceVariant,
                );
                expect(
                  theme.segmentedButtonTheme.style!.backgroundColor!.resolve({
                    WidgetState.selected,
                  }),
                  data.tonalControlFill(scheme),
                );
                expect(
                  theme.segmentedButtonTheme.style!.foregroundColor!.resolve({
                    WidgetState.selected,
                  }),
                  data.onTonalControlFill(scheme),
                );
                expect(
                  theme.chipTheme.selectedColor,
                  data.tonalControlFill(scheme),
                );
                expect(
                  WidgetStateProperty.resolveAs(theme.chipTheme.labelStyle!, {
                    WidgetState.selected,
                  }).color,
                  data.onTonalControlFill(scheme),
                );
                expect(
                  theme.floatingActionButtonTheme.backgroundColor,
                  Colors.white,
                );
                expect(
                  theme.floatingActionButtonTheme.foregroundColor,
                  data.onPlayButtonFill(scheme),
                );
                // One IconButtonTheme serves filled and plain constructors.
                expect(theme.iconButtonTheme.style!.backgroundColor, isNull);
              }
            }
          }
        }
      });
    }
  }

  test('Controls participates in extension equality, copy, snap and cache', () {
    const accent = NavisColorStyleData(
      style: NavisColorStyle.pastel,
      dark: false,
    );
    final white = accent.copyWith(controls: NavisControlColor.white);
    const whiteAdjustment = ColorAdjustment(controls: NavisControlColor.white);
    expect(
      accent.copyWith(adjustment: whiteAdjustment).controls,
      NavisControlColor.white,
    );

    expect(white, isNot(accent));
    expect(white.hashCode, white.copyWith().hashCode);
    expect(white.copyWith(), white);
    expect(accent.lerp(white, 0.49), same(accent));
    expect(accent.lerp(white, 0.5), same(white));
    final cache = NavisThemeCache();
    ThemeData resolve(ColorAdjustment adj) => cache.resolve(
      seed: Colors.purple,
      brightness: Brightness.light,
      oled: false,
      style: NavisColorStyle.pastel,
      flat: false,
      corners: NavisCornerStyle.rounded,
      adjustment: adj,
    );
    final base = resolve(ColorAdjustment.none);
    final tinted = resolve(const ColorAdjustment(tint: 3));
    final whiteTheme = resolve(
      const ColorAdjustment(controls: NavisControlColor.white),
    );
    expect(tinted, isNot(same(base)));
    expect(whiteTheme, isNot(same(base)));
    expect(whiteTheme.colorScheme, base.colorScheme);
    expect(resolve(const ColorAdjustment(tint: 3)), same(tinted));
    expect(
      resolve(const ColorAdjustment(controls: NavisControlColor.white)),
      same(whiteTheme),
    );
  });
}
