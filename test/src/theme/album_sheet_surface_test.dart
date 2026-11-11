import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/album_sheet_surface.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';

const _seeds = <String, int>{
  'yellow': 0xFFFFFF00,
  'near black': 0xFF050505,
  'near white': 0xFFFAFAFA,
  'blue': 0xFF0000FF,
  'red': 0xFFFF0000,
};

ThemeData _theme(String mode, NavisColorStyle style, [Color? seed]) {
  final s = seed ?? const Color(0xFF009688);
  return switch (mode) {
    'light' => buildLightTheme(s, style: style),
    'dark' => buildDarkTheme(s, style: style),
    _ => buildOledTheme(s, style: style),
  };
}

Color _base(ThemeData theme) {
  final scheme = theme.colorScheme;
  return theme.extension<NavisColorStyleData>()!.oled
      ? scheme.surfaceContainer
      : scheme.surfaceContainerLow;
}

double _floor(Color text, Color base) {
  final baseline = captionContrast(text, base);
  return baseline < kCaptionMinContrast ? baseline : kCaptionMinContrast;
}

void main() {
  for (final mode in ['light', 'dark', 'oled']) {
    for (final style in NavisColorStyle.values) {
      for (final entry in _seeds.entries) {
        test('${entry.key} in $mode ${style.name} keeps text readable', () {
          final theme = _theme(mode, style);
          final scheme = theme.colorScheme;
          final data = theme.extension<NavisColorStyleData>()!;
          final fill = albumSheetSurface(
            seed: entry.value,
            scheme: scheme,
            style: data,
          );
          if (fill == null) return;
          expect(fill.a, 1);
          expect(
            captionContrast(scheme.onSurface, fill),
            greaterThanOrEqualTo(_floor(scheme.onSurface, _base(theme))),
          );
          expect(
            captionContrast(scheme.onSurfaceVariant, fill),
            greaterThanOrEqualTo(_floor(scheme.onSurfaceVariant, _base(theme))),
          );
          if (mode == 'oled') {
            expect(fill.computeLuminance(), lessThan(0.08));
          }
          // Pin the share set: OLED mixes only 0.08 / 0.05 / 0.03 of the seed.
          final tint = Color(entry.value).withValues(alpha: 1);
          final steps = mode == 'oled'
              ? const [0.08, 0.05, 0.03]
              : const [0.16, 0.10, 0.05];
          expect(
            steps.map((step) => Color.lerp(_base(theme), tint, step)),
            contains(fill),
          );
        });
      }
    }
  }

  test('no seed gives no fill', () {
    final theme = _theme('dark', NavisColorStyle.neutral);
    expect(
      albumSheetSurface(
        seed: null,
        scheme: theme.colorScheme,
        style: theme.extension<NavisColorStyleData>()!,
      ),
      isNull,
    );
  });

  test('a visible seed actually tints the surface', () {
    final theme = _theme('dark', NavisColorStyle.neutral);
    final fill = albumSheetSurface(
      seed: 0xFF0000FF,
      scheme: theme.colorScheme,
      style: theme.extension<NavisColorStyleData>()!,
    );
    expect(fill, isNotNull);
    expect(fill, isNot(_base(theme)));
  });

  test(
    'a mismatched scheme (old fill, new text) falls back or stays legible',
    () {
      // The fill was made for the old song's scheme; the text now follows the
      // new scheme. Judge the new text against the old fill.
      for (final mode in ['light', 'dark', 'oled']) {
        for (final style in NavisColorStyle.values) {
          final old = _theme(mode, style, const Color(0xFFFFFF00));
          final next = _theme(mode, style, const Color(0xFF0000FF));
          final fill = albumSheetSurface(
            seed: _seeds['yellow'],
            scheme: old.colorScheme,
            style: old.extension<NavisColorStyleData>()!,
          );
          if (fill == null) continue;
          expect(
            captionContrast(next.colorScheme.onSurface, fill),
            greaterThanOrEqualTo(4.5),
            reason: '$mode ${style.name}',
          );
          expect(
            captionContrast(next.colorScheme.onSurfaceVariant, fill),
            greaterThanOrEqualTo(4.5),
            reason: '$mode ${style.name}',
          );
        }
      }
    },
  );
}
