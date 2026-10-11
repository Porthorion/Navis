import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';

const _seed = Color(0xFF3F7BE0);

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

ThemeData _theme(
  NavisColorStyle style,
  String mode,
  NavisControlColor controls,
  int tint,
) {
  final adjustment = ColorAdjustment(controls: controls, tint: tint);
  return switch (mode) {
    'light' => buildLightTheme(_seed, style: style, adjustment: adjustment),
    'dark' => buildDarkTheme(_seed, style: style, adjustment: adjustment),
    _ => buildOledTheme(_seed, style: style, adjustment: adjustment),
  };
}

Future<void> _pump(WidgetTester tester, ThemeData theme, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );
  // MaterialApp animates a changed theme.
  await tester.pumpAndSettle();
}

/// The fill a button actually paints, over the page when it has none.
Color _fill(WidgetTester tester, Finder button, Color page) {
  final material = tester.widget<Material>(
    find.descendant(of: button, matching: find.byType(Material)).first,
  );
  return Color.alphaBlend(material.color ?? Colors.transparent, page);
}

/// The colour a glyph actually resolves to.
Color? _glyph(WidgetTester tester, IconData icon) =>
    IconTheme.of(tester.element(find.byIcon(icon))).color;

void main() {
  for (final style in NavisColorStyle.values) {
    for (final mode in <String>['light', 'dark', 'oled']) {
      for (final controls in NavisControlColor.values) {
        final name = '${style.name} $mode ${controls.name}';

        testWidgets('Play is solid and Shuffle tonal ($name)', (tester) async {
          for (final tint in <int>[0, 5]) {
            final theme = _theme(style, mode, controls, tint);
            final scheme = theme.colorScheme;
            final data = theme.extension<NavisColorStyleData>()!;
            final page = theme.scaffoldBackgroundColor;
            for (final compact in <bool>[false, true]) {
              await _pump(
                tester,
                theme,
                EntityActionBar(
                  compact: compact,
                  onPlay: () {},
                  onShuffle: () {},
                  playKey: const ValueKey('play'),
                  shuffleKey: const ValueKey('shuffle'),
                ),
              );
              final reason = '$name tint $tint compact $compact';
              expect(
                _fill(tester, find.byKey(const ValueKey('play')), page),
                data.playButtonFill(scheme),
                reason: reason,
              );
              expect(
                _glyph(tester, Icons.play_arrow_rounded),
                data.onPlayButtonFill(scheme),
                reason: reason,
              );
              expect(
                _fill(tester, find.byKey(const ValueKey('shuffle')), page),
                data.tonalControlFill(scheme),
                reason: reason,
              );
              expect(
                _glyph(tester, Icons.shuffle_rounded),
                data.onTonalControlFill(scheme),
                reason: reason,
              );
              if (controls == NavisControlColor.accent) {
                expect(data.playButtonFill(scheme), scheme.primary);
                expect(
                  data.tonalControlFill(scheme),
                  scheme.secondaryContainer,
                );
              } else {
                expect(data.playButtonFill(scheme), Colors.white);
                expect(data.onPlayButtonFill(scheme), isNot(Colors.white));
              }
            }
          }
        });

        testWidgets('a toggle is more visible on than off ($name)', (
          tester,
        ) async {
          for (final tint in <int>[0, 5]) {
            final theme = _theme(style, mode, controls, tint);
            final scheme = theme.colorScheme;
            final data = theme.extension<NavisColorStyleData>()!;
            final page = theme.scaffoldBackgroundColor;
            await _pump(
              tester,
              theme,
              Builder(
                builder: (context) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final on in <bool>[true, false])
                      IconButton.filledTonal(
                        key: ValueKey<bool>(on),
                        style: NavisColorStyleData.tonalStyleOf(
                          context,
                          selected: on,
                        ),
                        isSelected: on,
                        onPressed: () {},
                        icon: const Icon(Icons.favorite_border_rounded),
                        selectedIcon: const Icon(Icons.favorite_rounded),
                      ),
                  ],
                ),
              ),
            );
            final on = _fill(tester, find.byKey(const ValueKey(true)), page);
            final off = _fill(tester, find.byKey(const ValueKey(false)), page);
            final reason = '$name tint $tint';
            expect(on, data.tonalControlFill(scheme), reason: reason);
            expect(
              _glyph(tester, Icons.favorite_rounded),
              data.onTonalControlFill(scheme),
              reason: reason,
            );
            expect(
              _glyph(tester, Icons.favorite_border_rounded),
              scheme.onSurfaceVariant,
              reason: reason,
            );
            // Off paints no fill, so its page contrast is 1:1.
            expect(off, page, reason: reason);
            expect(on, isNot(page), reason: reason);
            expect(
              _contrast(on, page),
              greaterThan(_contrast(off, page)),
              reason: reason,
            );
            expect(
              _contrast(data.onTonalControlFill(scheme), on),
              greaterThanOrEqualTo(4.5),
              reason: reason,
            );
          }
        });
      }

      testWidgets('FAB is the solid action; plain icons stay ink '
          '(${style.name} $mode)', (tester) async {
        for (final controls in NavisControlColor.values) {
          final theme = _theme(style, mode, controls, 0);
          final scheme = theme.colorScheme;
          final data = theme.extension<NavisColorStyleData>()!;
          await _pump(
            tester,
            theme,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FloatingActionButton(
                  onPressed: () {},
                  child: const Icon(Icons.add),
                ),
                IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.skip_next_rounded),
                ),
              ],
            ),
          );
          expect(
            _fill(
              tester,
              find.byType(FloatingActionButton),
              theme.scaffoldBackgroundColor,
            ),
            data.playButtonFill(scheme),
            reason: controls.name,
          );
          expect(
            _glyph(tester, Icons.add),
            data.onPlayButtonFill(scheme),
            reason: controls.name,
          );
          expect(
            _glyph(tester, Icons.skip_next_rounded),
            scheme.onSurfaceVariant,
            reason: controls.name,
          );
        }
      });
    }
  }

  testWidgets('White Light fills carry the accent hairline, Dark none', (
    tester,
  ) async {
    for (final mode in <String>['light', 'dark']) {
      final theme = _theme(
        NavisColorStyle.pastel,
        mode,
        NavisControlColor.white,
        0,
      );
      final data = theme.extension<NavisColorStyleData>()!;
      await _pump(
        tester,
        theme,
        EntityActionBar(
          onPlay: () {},
          onShuffle: () {},
          playKey: const ValueKey('play'),
          shuffleKey: const ValueKey('shuffle'),
        ),
      );
      for (final key in <String>['play', 'shuffle']) {
        final material = tester.widget<Material>(
          find
              .descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(Material),
              )
              .first,
        );
        final shape = material.shape! as OutlinedBorder;
        expect(
          shape.side.color,
          mode == 'light' ? data.controlEdge : isNot(data.controlEdge),
          reason: '$mode $key',
        );
        expect(shape.side.width, mode == 'light' ? 1 : 0, reason: '$mode $key');
      }
    }
  });

  testWidgets('White controls: switch, slider and chips resolve white fills '
      'with accent glyphs', (tester) async {
    for (final mode in <String>['light', 'dark']) {
      final theme = _theme(
        NavisColorStyle.pastel,
        mode,
        NavisControlColor.white,
        0,
      );
      final scheme = theme.colorScheme;
      final data = theme.extension<NavisColorStyleData>()!;
      late BuildContext inner;
      await _pump(
        tester,
        theme,
        Builder(
          builder: (context) {
            inner = context;
            return const SizedBox();
          },
        ),
      );
      expect(SliderTheme.of(inner).activeTrackColor, Colors.white);
      expect(SliderTheme.of(inner).thumbColor, Colors.white);
      expect(
        SwitchTheme.of(inner).thumbColor!.resolve({WidgetState.selected}),
        Colors.white,
      );
      expect(
        SwitchTheme.of(inner).trackColor!.resolve({WidgetState.selected}),
        scheme.primary,
      );
      expect(ChipTheme.of(inner).selectedColor, data.tonalControlFill(scheme));
      expect(
        NavigationBarTheme.of(inner).indicatorColor,
        data.tonalControlFill(scheme),
      );
    }
  });
}
