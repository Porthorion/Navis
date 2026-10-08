import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/theme/navis_tokens.dart';

const Map<String, Color> _seeds = <String, Color>{
  'white (default)': Colors.white,
  'grey': Color(0xFF9E9E9E),
  'yellow': Color(0xFFFFEB3B),
  'cover yellow': Color(0xFFF2B630),
  'orange': Color(0xFFFF9800),
  'cover orange-red': Color(0xFFE2581E),
  'red': Color(0xFFF44336),
  'magenta': Color(0xFFE91E63),
  'blue': Color(0xFF2196F3),
  'green': Color(0xFF4CAF50),
  'brown': Color(0xFF795548),
};

enum _Mode { light, dark, oled }

ColorScheme _scheme(Color seed, _Mode mode, NavisColorStyle style) {
  return buildStyledColorScheme(
    seed: seed,
    brightness: mode == _Mode.light ? Brightness.light : Brightness.dark,
    oled: mode == _Mode.oled,
    style: style,
  );
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Hct _hct(Color color) => Hct.fromInt(color.toARGB32());

void main() {
  const styled = <NavisColorStyle>[
    NavisColorStyle.pastel,
    NavisColorStyle.immersive,
    NavisColorStyle.night,
  ];
  const checked = <NavisColorStyle>[NavisColorStyle.neutral, ...styled];

  group('styled schemes', () {
    for (final style in checked) {
      for (final mode in _Mode.values) {
        for (final entry in _seeds.entries) {
          final label = '${style.name} ${mode.name} ${entry.key}';
          final scheme = _scheme(entry.value, mode, style);

          test('$label keeps text and controls readable', () {
            final pairs = <String, (Color, Color, double)>{
              'onSurface/surface': (scheme.onSurface, scheme.surface, 7),
              'onSurface/highest': (
                scheme.onSurface,
                scheme.surfaceContainerHighest,
                7,
              ),
              'onSurfaceVariant/surface': (
                scheme.onSurfaceVariant,
                scheme.surface,
                4.5,
              ),
              'onSurfaceVariant/highest': (
                scheme.onSurfaceVariant,
                scheme.surfaceContainerHighest,
                4.5,
              ),
              'onPrimary/primary': (scheme.onPrimary, scheme.primary, 4.5),
              'onPrimaryContainer/primaryContainer': (
                scheme.onPrimaryContainer,
                scheme.primaryContainer,
                4.5,
              ),
              'onSecondary/secondary': (
                scheme.onSecondary,
                scheme.secondary,
                4.5,
              ),
              'onSecondaryContainer/secondaryContainer': (
                scheme.onSecondaryContainer,
                scheme.secondaryContainer,
                4.5,
              ),
              'onTertiary/tertiary': (scheme.onTertiary, scheme.tertiary, 4.5),
              'onTertiaryContainer/tertiaryContainer': (
                scheme.onTertiaryContainer,
                scheme.tertiaryContainer,
                4.5,
              ),
              'onError/error': (scheme.onError, scheme.error, 4.5),
              'onErrorContainer/errorContainer': (
                scheme.onErrorContainer,
                scheme.errorContainer,
                4.5,
              ),
              'onInverseSurface/inverseSurface': (
                scheme.onInverseSurface,
                scheme.inverseSurface,
                4.5,
              ),
              'primary/surface': (scheme.primary, scheme.surface, 3),
              'primary/highest': (
                scheme.primary,
                scheme.surfaceContainerHighest,
                3,
              ),
              'error/surface': (scheme.error, scheme.surface, 3),
            };
            for (final pair in pairs.entries) {
              final (fg, bg, minimum) = pair.value;
              expect(
                _contrast(fg, bg),
                greaterThanOrEqualTo(minimum),
                reason: '$label ${pair.key}',
              );
            }
          });

          if (style == NavisColorStyle.neutral && mode == _Mode.light) {
            continue;
          }
          test('$label keeps fills and surfaces out of the muddy band', () {
            final fills = <String, Color>{
              'primaryContainer': scheme.primaryContainer,
              'secondaryContainer': scheme.secondaryContainer,
              'tertiaryContainer': scheme.tertiaryContainer,
              // Neutral leaves errors alarming on purpose.
              if (style != NavisColorStyle.neutral)
                'errorContainer': scheme.errorContainer,
              'surface': scheme.surface,
              'surfaceContainerLow': scheme.surfaceContainerLow,
              'surfaceContainer': scheme.surfaceContainer,
              'surfaceContainerHigh': scheme.surfaceContainerHigh,
              'surfaceContainerHighest': scheme.surfaceContainerHighest,
              if (mode != _Mode.light) 'primary': scheme.primary,
              if (mode != _Mode.light) 'secondary': scheme.secondary,
            };
            for (final fill in fills.entries) {
              final hct = _hct(fill.value);
              // Neutral only de-muds warm hues; cool hues stay as Material
              // builds them.
              if (style == NavisColorStyle.neutral && !isWarmHue(hct.hue)) {
                continue;
              }
              if (hct.tone >= 25 && hct.tone <= 50) {
                expect(
                  hct.chroma,
                  lessThanOrEqualTo(24.5),
                  reason: '$label ${fill.key} tone ${hct.tone}',
                );
              }
            }
          });

          if (mode == _Mode.oled && style != NavisColorStyle.neutral) {
            test('$label keeps OLED backgrounds pure black', () {
              expect(scheme.surface, Colors.black);
              expect(scheme.surfaceContainerLowest, Colors.black);
            });
          }
        }
      }
    }
  });

  test('dark yellows turn warm umber instead of khaki', () {
    for (final style in styled) {
      final scheme = _scheme(const Color(0xFFFFEB3B), _Mode.dark, style);
      for (final role in <Color>[
        scheme.surface,
        scheme.surfaceContainerHigh,
        scheme.primaryContainer,
      ]) {
        final hct = _hct(role);
        if (hct.chroma > 3) {
          final khaki = hct.hue > 75 && hct.hue < 125;
          expect(khaki, isFalse, reason: '${style.name} $hct');
        }
      }
    }
  });

  test('pastel tints its backgrounds and softens dark accent fills', () {
    for (final mode in <_Mode>[_Mode.light, _Mode.dark]) {
      final scheme = _scheme(
        const Color(0xFFF44336),
        mode,
        NavisColorStyle.pastel,
      );
      expect(_hct(scheme.surface).chroma, greaterThanOrEqualTo(4));
      if (mode == _Mode.dark) {
        expect(_hct(scheme.primary).chroma, lessThanOrEqualTo(44.5));
      }
    }
  });

  test('pastel light paper is visibly tinted for warm seeds', () {
    for (final seed in <Color>[
      const Color(0xFFF44336),
      const Color(0xFFE2581E),
    ]) {
      final surface = _scheme(
        seed,
        _Mode.light,
        NavisColorStyle.pastel,
      ).surface;
      expect(
        _hct(surface).chroma,
        greaterThanOrEqualTo(6),
        reason: 'surface ${_hct(surface)} for $seed',
      );
    }
  });

  test('pastel dark sets warm accents on a plum dusk', () {
    for (final seed in <Color>[
      const Color(0xFFE2581E),
      const Color(0xFFFFEB3B),
    ]) {
      final surface = _scheme(seed, _Mode.dark, NavisColorStyle.pastel).surface;
      final hue = _hct(surface).hue;
      expect(hue > 300 || hue < 10, isTrue, reason: 'hue $hue for $seed');
    }
  });

  test('pastel and immersive give the default white seed a sea-glass hue', () {
    for (final style in <NavisColorStyle>[
      NavisColorStyle.pastel,
      NavisColorStyle.immersive,
    ]) {
      final primary = _scheme(Colors.white, _Mode.dark, style).primary;
      expect(_hct(primary).hue, closeTo(seaGlassHue, 12));
    }
  });

  test('night moves cool accents into the warm range', () {
    for (final seed in <Color>[
      const Color(0xFF2196F3),
      const Color(0xFF4CAF50),
      const Color(0xFF9C27B0),
    ]) {
      final hue = _hct(_scheme(seed, _Mode.dark, NavisColorStyle.night).primary)
          .hue;
      final warm = hue >= 10 && hue <= 100;
      expect(warm, isTrue, reason: 'hue $hue for $seed');
    }
  });

  group('neutral style', () {
    const seed = Color(0xFF2196F3);

    test('matches the original schemes apart from dark containers', () {
      ColorScheme fidelity(Color seed) => ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      );
      expect(
        buildLightTheme(seed).colorScheme,
        ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
          dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
        ),
      );
      expect(buildDarkTheme(Colors.white).colorScheme, fidelity(Colors.white));
      const saturated = Color(0xFFE2581E);
      final dark = buildDarkTheme(saturated).colorScheme;
      final base = fidelity(saturated);
      expect(
        dark,
        base.copyWith(
          primaryContainer: dark.primaryContainer,
          secondaryContainer: dark.secondaryContainer,
          tertiaryContainer: dark.tertiaryContainer,
        ),
      );
      expect(dark.errorContainer, base.errorContainer);
      expect(dark.primary, base.primary);
      // Fidelity puts the secondary container at tone 30, chroma 40.
      expect(dark.secondaryContainer, isNot(base.secondaryContainer));
      expect(_hct(dark.secondaryContainer).chroma, lessThanOrEqualTo(20.5));
      final oled = buildOledTheme(seed);
      expect(oled.colorScheme.surface, Colors.black);
      expect(oled.colorScheme.surfaceContainerLow, const Color(0xFF0A0A0A));
      expect(oled.colorScheme.surfaceContainerHighest, const Color(0xFF121212));
      expect(oled.cardTheme.color, const Color(0xFF0A0A0A));
      expect(oled.scaffoldBackgroundColor, Colors.black);
    });

    test('keeps the original success greens', () {
      expect(
        buildDarkTheme(seed).extension<NavisTokens>()!.success,
        const Color(0xFF81C995),
      );
      expect(
        buildLightTheme(seed).extension<NavisTokens>()!.success,
        const Color(0xFF2E7D32),
      );
    });

    test('leaves artwork colours untouched', () {
      const data = NavisColorStyleData.neutralDark;
      const raw = Color(0xFF6B6B2A);
      expect(data.adaptArtColor(raw), raw);
      expect(data.artWashVeil(subtle: false), 0.66);
      expect(data.nowPlayingTintAlpha, 0.4);
    });
  });

  test('styled themes register the style and follow the styled accent', () {
    final theme = buildDarkTheme(
      const Color(0xFFE2581E),
      style: NavisColorStyle.pastel,
    );
    final data = theme.extension<NavisColorStyleData>()!;
    expect(data.style, NavisColorStyle.pastel);
    expect(data.dark, isTrue);
    expect(
      theme.extension<NavisAccentColors>()!.source,
      theme.colorScheme.primary,
    );
    expect(theme.extension<NavisTokens>()!.success, data.success);
  });

  test('light pastel fills buttons with the pastel container', () {
    final theme = buildLightTheme(
      const Color(0xFF2196F3),
      style: NavisColorStyle.pastel,
    );
    final background = theme.filledButtonTheme.style!.backgroundColor!.resolve(
      <WidgetState>{},
    );
    expect(background, theme.colorScheme.primaryContainer);
  });

  test('styled OLED cards and sheets carry the style hue', () {
    final theme = buildOledTheme(
      const Color(0xFF2196F3),
      style: NavisColorStyle.immersive,
    );
    expect(theme.scaffoldBackgroundColor, Colors.black);
    expect(theme.cardTheme.color, theme.colorScheme.surfaceContainerLow);
    expect(theme.cardTheme.color, isNot(const Color(0xFF0A0A0A)));
  });

  group('artwork colour adaptation', () {
    const oliveSample = Color(0xFF6B6B2A);

    for (final style in styled) {
      test('${style.name} keeps a dark yellow cover out of olive', () {
        final adapted = NavisColorStyleData(
          style: style,
          dark: true,
        ).adaptArtColor(oliveSample);
        final hct = _hct(adapted);
        // Pastel rotates warm hues into the rose/plum range (>= 300).
        expect(hct.hue < 80 || hct.hue >= 300, isTrue, reason: '$hct');
      });

      test('${style.name} lifts light-theme washes to pale tones', () {
        final adapted = NavisColorStyleData(
          style: style,
          dark: false,
        ).adaptArtColor(const Color(0xFF1E3A8A));
        expect(_hct(adapted).tone, greaterThanOrEqualTo(77));
      });
    }

    for (final raw in const <Color>[Color(0xFFE2581E), Color(0xFFF2B630)]) {
      for (final oled in <bool>[false, true]) {
        test('pastel dark turns ${raw.toARGB32().toRadixString(16)} '
            'rose or plum, not brown (oled: $oled)', () {
          final adapted = NavisColorStyleData(
            style: NavisColorStyle.pastel,
            dark: true,
            oled: oled,
          ).adaptArtColor(raw);
          final hue = _hct(adapted).hue;
          expect(hue >= 300 || hue <= 20, isTrue, reason: 'hue $hue');
        });
      }
    }

    test('pastel light and night dark keep their hues', () {
      const orange = Color(0xFFE2581E);
      final light = NavisColorStyleData(
        style: NavisColorStyle.pastel,
        dark: false,
      ).adaptArtColor(orange);
      expect(_hct(light).hue, closeTo(_hct(orange).hue, 6));
      final night = NavisColorStyleData(
        style: NavisColorStyle.night,
        dark: true,
      ).adaptArtColor(orange);
      expect(_hct(night).hue, inInclusiveRange(15, 95));
    });

    test('immersive dark caps warm chroma but keeps the hue', () {
      const orange = Color(0xFFE2581E);
      final adapted = NavisColorStyleData(
        style: NavisColorStyle.immersive,
        dark: true,
      ).adaptArtColor(orange);
      expect(_hct(adapted).chroma, lessThanOrEqualTo(23));
      expect(_hct(adapted).hue, closeTo(_hct(orange).hue, 8));
      const blue = Color(0xFF1E3A8A);
      final cool = NavisColorStyleData(
        style: NavisColorStyle.immersive,
        dark: true,
      ).adaptArtColor(blue);
      expect(_hct(cool).chroma, greaterThan(23));
    });
  });

  group('artwork scrim', () {
    test('neutral is pure black', () {
      expect(NavisColorStyleData.neutralDark.artworkScrim, Colors.black);
      final theme = buildDarkTheme(const Color(0xFFE2581E));
      expect(
        theme.extension<NavisColorStyleData>()!.artworkScrim,
        Colors.black,
      );
    });

    for (final style in styled) {
      test('${style.name} is a near-black tint, not black', () {
        final theme = buildDarkTheme(const Color(0xFFE2581E), style: style);
        final scrim = theme.extension<NavisColorStyleData>()!.artworkScrim;
        expect(scrim, isNot(Colors.black));
        expect(_hct(scrim).tone, inInclusiveRange(4, 9));
        expect(_hct(scrim).chroma, greaterThan(3));
      });
    }

    test('pastel follows the dusk hue and OLED is recorded', () {
      final theme = buildOledTheme(
        const Color(0xFFE2581E),
        style: NavisColorStyle.pastel,
      );
      final data = theme.extension<NavisColorStyleData>()!;
      expect(data.oled, isTrue);
      expect(_hct(data.artworkScrim).hue, closeTo(340, 12));
    });
  });
}
