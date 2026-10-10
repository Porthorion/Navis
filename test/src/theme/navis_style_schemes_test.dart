import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/flat_band_tone.dart';
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
  'neon pink': Color(0xFFFF1493),
  'dark navy': Color(0xFF0A1F5C),
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

  group('colour adjustments', () {
    const extremes = [
      ColorAdjustment(vividness: -5),
      ColorAdjustment(vividness: 5),
      ColorAdjustment(depth: -5),
      ColorAdjustment(depth: 5),
      ColorAdjustment(vividness: -5, depth: -5),
      ColorAdjustment(vividness: -5, depth: 5),
      ColorAdjustment(vividness: 5, depth: -5),
      ColorAdjustment(vividness: 5, depth: 5),
    ];
    for (final style in checked) {
      for (final mode in _Mode.values) {
        for (final entry in _seeds.entries) {
          final base = _scheme(entry.value, mode, style);
          final dark = mode != _Mode.light;
          final oled = mode == _Mode.oled;
          final label = '${style.name} ${mode.name} ${entry.key}';
          test('$label identity and monotonic tuning', () {
            expect(
              adjustColorScheme(
                base,
                ColorAdjustment.none,
                dark: dark,
                oled: oled,
              ),
              same(base),
            );
            ColorScheme at(ColorAdjustment adj) => buildStyledColorScheme(
              seed: entry.value,
              brightness: dark ? Brightness.dark : Brightness.light,
              oled: oled,
              style: style,
              adjustment: adj,
            );
            final muted = at(const ColorAdjustment(vividness: -5));
            final vivid = at(const ColorAdjustment(vividness: 5));
            // Every Color step is at least as colourful as the one before.
            // The tolerance covers 8-bit rounding and the sRGB gamut edge.
            var previous = _hct(muted.primary).chroma;
            for (var v = -4; v <= 5; v++) {
              final chroma = _hct(at(ColorAdjustment(vividness: v)).primary)
                  .chroma;
              expect(
                chroma,
                greaterThanOrEqualTo(previous - 0.6),
                reason: 'v=$v',
              );
              previous = chroma;
            }
            // Brightness alone never changes the accents.
            for (final d in const [-5, 5]) {
              final shifted = at(ColorAdjustment(depth: d));
              expect(shifted.primary, base.primary, reason: 'd=$d');
              expect(shifted.secondary, base.secondary, reason: 'd=$d');
              expect(shifted.tertiary, base.tertiary, reason: 'd=$d');
            }
            // Fidelity can map a saturated yellow seed to pure white. The
            // post-pass deliberately preserves pure black/white roles.
            if (_hct(entry.value).chroma >= 8 &&
                base.primary != Colors.white &&
                base.primary != Colors.black) {
              expect(
                _hct(vivid.primary).chroma,
                greaterThan(_hct(muted.primary).chroma),
              );
            }
            final lighter = at(const ColorAdjustment(depth: -5));
            final deeper = at(const ColorAdjustment(depth: 5));
            if (oled) {
              expect(lighter.surface, Colors.black);
              expect(deeper.surface, Colors.black);
            } else {
              expect(
                _hct(deeper.surface).tone,
                lessThan(_hct(lighter.surface).tone),
              );
            }
          });
          for (final adj in extremes) {
            test('$label extremes v=${adj.vividness} d=${adj.depth}', () {
              final scheme = buildStyledColorScheme(
                seed: entry.value,
                brightness: dark ? Brightness.dark : Brightness.light,
                oled: oled,
                style: style,
                adjustment: adj,
              );
              for (final pair in _readablePairs(scheme).entries) {
                final (fg, bg, minimum) = pair.value;
                expect(
                  _contrast(fg, bg),
                  greaterThanOrEqualTo(minimum),
                  reason: pair.key,
                );
              }
              final containers = [
                scheme.surfaceContainerLowest,
                scheme.surfaceContainerLow,
                scheme.surfaceContainer,
                scheme.surfaceContainerHigh,
                scheme.surfaceContainerHighest,
              ];
              if (oled) {
                expect(scheme.surface, Colors.black);
                expect(scheme.surfaceDim, Colors.black);
                expect(scheme.surfaceContainerLowest, Colors.black);
                for (final color in containers) {
                  expect(_hct(color).chroma, lessThanOrEqualTo(3));
                }
              }
              // Same roles as the default muddy-band test below: fills and
              // surfaces, plus primary and secondary in dark modes. Light
              // ink accents and inverse roles sit outside the rule.
              for (final color in [
                scheme.primaryContainer,
                scheme.secondaryContainer,
                scheme.tertiaryContainer,
                scheme.surface,
                scheme.surfaceDim,
                scheme.surfaceContainerLowest,
                ...containers,
                if (dark) scheme.primary,
                if (dark) scheme.secondary,
              ]) {
                final value = _hct(color);
                if (style == NavisColorStyle.neutral && !isWarmHue(value.hue)) {
                  continue;
                }
                if (value.tone >= 25 && value.tone <= 50) {
                  expect(
                    value.chroma,
                    lessThanOrEqualTo(24.5),
                    reason: '$color tone=${value.tone}',
                  );
                }
              }
              expect(scheme.onSurface, base.onSurface);
              expect(scheme.onPrimary, base.onPrimary);
              expect(scheme.error, base.error);
              expect(scheme.onError, base.onError);
            });
          }
        }
      }
    }
  });

  group('styled schemes', () {
    for (final style in checked) {
      for (final mode in _Mode.values) {
        for (final entry in _seeds.entries) {
          final label = '${style.name} ${mode.name} ${entry.key}';
          final scheme = _scheme(entry.value, mode, style);

          test('$label keeps text and controls readable', () {
            final pairs = _readablePairs(scheme);
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

  test('OLED containers stay near-black (chroma <= 2) in every style', () {
    for (final style in checked) {
      for (final entry in _seeds.entries) {
        final scheme = _scheme(entry.value, _Mode.oled, style);
        final containers = <String, Color>{
          'low': scheme.surfaceContainerLow,
          'container': scheme.surfaceContainer,
          'high': scheme.surfaceContainerHigh,
          'highest': scheme.surfaceContainerHighest,
        };
        containers.forEach((name, color) {
          expect(
            _hct(color).chroma,
            // Capped at 2; 8-bit rounding of near-black tones adds under 1.
            lessThanOrEqualTo(3),
            reason: '${style.name} ${entry.key} $name',
          );
        });
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
        expect(_hct(scheme.primary).chroma, lessThanOrEqualTo(24.5));
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
        greaterThanOrEqualTo(5),
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

  group('style separation', () {
    double maxChroma(ColorScheme scheme) => <Color>[
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
      scheme.primaryContainer,
      scheme.secondaryContainer,
      scheme.tertiaryContainer,
      scheme.surface,
      scheme.surfaceContainer,
      scheme.surfaceContainerHighest,
    ].map((c) => _hct(c).chroma).reduce((a, b) => a > b ? a : b);

    for (final mode in _Mode.values) {
      for (final entry in _seeds.entries) {
        final label = '${mode.name} ${entry.key}';
        final pastel = _scheme(entry.value, mode, NavisColorStyle.pastel);
        final immersive = _scheme(entry.value, mode, NavisColorStyle.immersive);
        final night = _scheme(entry.value, mode, NavisColorStyle.night);

        test('$label: pastel is >= 40% less chromatic than immersive', () {
          expect(
            maxChroma(pastel),
            lessThanOrEqualTo(maxChroma(immersive) * 0.6),
            reason:
                'pastel ${maxChroma(pastel)} immersive '
                '${maxChroma(immersive)}',
          );
          expect(
            maxChroma(pastel),
            lessThan(maxChroma(night) * 0.85),
            reason: 'pastel ${maxChroma(pastel)} night ${maxChroma(night)}',
          );
          // Containers are softer too, not only the accents.
          for (final pair in <(Color, Color)>[
            (pastel.primaryContainer, immersive.primaryContainer),
            (pastel.secondaryContainer, immersive.secondaryContainer),
          ]) {
            expect(_hct(pair.$1).chroma, lessThan(_hct(pair.$2).chroma + 0.5));
          }
        });

        test('$label: pastel stays soft (macaron accents, quiet fills)', () {
          expect(_hct(pastel.primary).chroma, lessThanOrEqualTo(24.5));
          expect(_hct(pastel.secondary).chroma, lessThanOrEqualTo(24.5));
          expect(_hct(pastel.tertiary).chroma, lessThanOrEqualTo(24.5));
          for (final fill in <Color>[
            pastel.primaryContainer,
            pastel.secondaryContainer,
            pastel.tertiaryContainer,
          ]) {
            expect(_hct(fill).chroma, lessThanOrEqualTo(20.5));
          }
          for (final surface in <Color>[
            pastel.surface,
            pastel.surfaceContainer,
            pastel.surfaceContainerHighest,
          ]) {
            expect(_hct(surface).chroma, lessThanOrEqualTo(10.5));
          }
          if (mode == _Mode.light) {
            expect(_hct(pastel.primary).tone, inInclusiveRange(45, 55));
            for (final fill in <Color>[
              pastel.primaryContainer,
              pastel.secondaryContainer,
              pastel.tertiaryContainer,
            ]) {
              expect(_hct(fill).tone, inInclusiveRange(87.5, 93));
            }
          } else {
            expect(_hct(pastel.primary).tone, greaterThanOrEqualTo(83.5));
            expect(_hct(pastel.tertiary).tone, greaterThanOrEqualTo(83.5));
            expect(_hct(pastel.primaryContainer).chroma, lessThan(14.5));
          }
        });

        test('$label: night stays warm and low-blue', () {
          expect(_hct(night.primary).hue, inInclusiveRange(12, 98));
          expect(_hct(night.tertiary).hue, inInclusiveRange(12, 98));
          expect(maxChroma(night), lessThanOrEqualTo(40.5));
          final roles = <Color>[
            night.onSurface,
            if (mode != _Mode.oled) night.surface,
            night.surfaceContainerHighest,
          ];
          for (final role in roles) {
            expect(role.b, lessThan(role.r), reason: 'night role $role');
          }
        });

        test('$label: immersive keeps rich accents', () {
          expect(maxChroma(immersive), greaterThanOrEqualTo(34));
          if (mode == _Mode.dark) {
            // Deep tinted surfaces; OLED stays near black, light is paper.
            expect(_hct(immersive.surface).chroma, greaterThanOrEqualTo(14));
          }
        });
      }
    }

    test('pastel softens the seed chroma instead of passing it through', () {
      for (final mode in _Mode.values) {
        final muted = _scheme(
          hct(350, 14, 50),
          mode,
          NavisColorStyle.pastel,
        ).primary;
        final vivid = _scheme(
          hct(350, 100, 50),
          mode,
          NavisColorStyle.pastel,
        ).primary;
        expect(_hct(vivid).chroma, lessThanOrEqualTo(24.5));
        expect(
          _hct(vivid).chroma - _hct(muted).chroma,
          lessThanOrEqualTo(9),
          reason: mode.name,
        );
        expect(_hct(vivid).hue, closeTo(_hct(muted).hue, 8));
      }
    });

    test('pastel success is soft, immersive success is richer', () {
      for (final dark in <bool>[false, true]) {
        final pastel = NavisColorStyleData(
          style: NavisColorStyle.pastel,
          dark: dark,
        ).success;
        final immersive = NavisColorStyleData(
          style: NavisColorStyle.immersive,
          dark: dark,
        ).success;
        expect(_hct(pastel).chroma, lessThanOrEqualTo(24.5));
        expect(_hct(pastel).chroma, lessThan(_hct(immersive).chroma * 0.6));
      }
    });
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

  group('artwork colours across styles', () {
    const samples = <String, Color>{
      'neon pink': Color(0xFFFF1493),
      'cover orange': Color(0xFFE2581E),
      'cover yellow': Color(0xFFF2B630),
      'electric blue': Color(0xFF1E3AEE),
      'green': Color(0xFF14C850),
      'navy': Color(0xFF0A1F5C),
      'mint': Color(0xFFB8E8D0),
    };
    // (dark, oled) combinations.
    const modes = <(bool, bool)>[(false, false), (true, false), (true, true)];

    for (final (dark, oled) in modes) {
      final pastelData = NavisColorStyleData(
        style: NavisColorStyle.pastel,
        dark: dark,
        oled: oled,
      );
      final immersiveData = pastelData.copyWith(
        style: NavisColorStyle.immersive,
      );
      for (final entry in samples.entries) {
        final label = '${entry.key} dark=$dark oled=$oled';

        test(
          '$label: pastel art colours cap at chroma 14 and trail immersive',
          () {
            final adapted = pastelData.adaptArtColor(entry.value);
            expect(_hct(adapted).chroma, lessThanOrEqualTo(14.5));
            expect(
              _hct(adapted).chroma,
              lessThan(
                _hct(immersiveData.adaptArtColor(entry.value)).chroma * 0.6,
              ),
            );
            // Flat bands and cover-tinted captions derive from the same colour.
            final band = flatBandSample(entry.value, pastelData);
            expect(_hct(band).chroma, lessThanOrEqualTo(14.5));
            final caption = captionTintFor(entry.value, pastelData).fill;
            expect(_hct(caption).chroma, lessThanOrEqualTo(14.5));
            expect(
              _hct(band).chroma,
              lessThan(
                _hct(flatBandSample(entry.value, immersiveData)).chroma * 0.65 +
                    0.5,
              ),
            );
          },
        );
      }
    }

    for (final dark in <bool>[false, true]) {
      test('flat Now Playing solid stays pastel (dark=$dark)', () {
        for (final entry in samples.entries) {
          Color solid(NavisColorStyle style) {
            final data = NavisColorStyleData(
              style: style,
              dark: dark,
              flat: true,
            );
            final surface = _scheme(
              Colors.white,
              dark ? _Mode.dark : _Mode.light,
              style,
            ).surface;
            return nowPlayingSurfaceDecoration(
              tintColor: entry.value,
              colorStyle: data,
              surfaceColor: surface,
            ).color!;
          }

          final pastel = solid(NavisColorStyle.pastel);
          expect(
            _hct(pastel).chroma,
            lessThanOrEqualTo(14.5),
            reason: entry.key,
          );
          expect(
            _hct(pastel).chroma,
            lessThan(_hct(solid(NavisColorStyle.immersive)).chroma),
            reason: entry.key,
          );
        }
      });
    }

    test('pastel light art colours are high-key, dark ones dusky-soft', () {
      for (final raw in samples.values) {
        final light = NavisColorStyleData(
          style: NavisColorStyle.pastel,
          dark: false,
        ).adaptArtColor(raw);
        final dusk = NavisColorStyleData(
          style: NavisColorStyle.pastel,
          dark: true,
        ).adaptArtColor(raw);
        expect(_hct(light).tone, greaterThanOrEqualTo(87.5));
        expect(_hct(dusk).tone, inInclusiveRange(25.5, 34.5));
      }
    });
  });

  group('light raised surfaces', () {
    for (final style in styled) {
      test('${style.name} sheets, menus and dialogs differ from the paper', () {
        final scheme = buildLightTheme(
          const Color(0xFFE2581E),
          style: style,
        ).colorScheme;
        final paper = _hct(scheme.surface).tone;
        for (final container in <Color>[
          scheme.surfaceContainerLow, // bottom sheets, cards
          scheme.surfaceContainer, // popup menus
          scheme.surfaceContainerHigh, // dialogs
        ]) {
          expect(paper - _hct(container).tone, greaterThanOrEqualTo(2.5));
        }
      });
    }
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

Map<String, (Color, Color, double)> _readablePairs(ColorScheme scheme) {
  return <String, (Color, Color, double)>{
    'onSurface/surface': (scheme.onSurface, scheme.surface, 7),
    'onSurface/highest': (scheme.onSurface, scheme.surfaceContainerHighest, 7),
    'onSurfaceVariant/surface': (scheme.onSurfaceVariant, scheme.surface, 4.5),
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
    'onSecondary/secondary': (scheme.onSecondary, scheme.secondary, 4.5),
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
    'primary/highest': (scheme.primary, scheme.surfaceContainerHighest, 3),
    'error/surface': (scheme.error, scheme.surface, 3),
  };
}
