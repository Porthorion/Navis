import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/home_notice_card.dart';
import 'package:navis/src/theme/corner_style_provider.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const Color _seed = Color(0xFF009688);

void main() {
  group('radius table', () {
    test('rounded is exactly the NavisRadius scale', () {
      final data = NavisShapeData.forStyle(NavisCornerStyle.rounded);
      expect(
        <double>[data.xs, data.sm, data.md, data.lg, data.xl],
        <double>[
          NavisRadius.xs,
          NavisRadius.sm,
          NavisRadius.md,
          NavisRadius.lg,
          NavisRadius.xl,
        ],
      );
      expect(data.controlShape, isA<StadiumBorder>());
      expect(NavisTokens.defaults.panelRadius, NavisRadius.xl);
    });

    test('soft is roughly 1.5x with pill controls', () {
      final data = NavisShapeData.forStyle(NavisCornerStyle.soft);
      expect(
        <double>[data.xs, data.sm, data.md, data.lg, data.xl],
        <double>[6, 12, 18, 24, 28],
      );
      expect(data.controlShape, isA<StadiumBorder>());
    });

    test('square is crisp with 4 px controls', () {
      final data = NavisShapeData.forStyle(NavisCornerStyle.square);
      expect(
        <double>[data.xs, data.sm, data.md, data.lg, data.xl],
        <double>[2, 2, 4, 4, 6],
      );
      expect(data.control, 4);
      expect(data.controlShape, isNot(isA<StadiumBorder>()));
    });

    test('parse falls back to rounded', () {
      expect(NavisCornerStyle.parse('soft'), NavisCornerStyle.soft);
      expect(NavisCornerStyle.parse('nope'), NavisCornerStyle.rounded);
      expect(NavisCornerStyle.parse(null), NavisCornerStyle.rounded);
    });
  });

  group('component themes', () {
    BorderRadius? radiusOf(ShapeBorder? shape) =>
        (shape as RoundedRectangleBorder?)?.borderRadius as BorderRadius?;

    test('rounded leaves Material defaults unset', () {
      final theme = buildDarkTheme(_seed);
      expect(theme.dialogTheme.shape, isNull);
      expect(theme.bottomSheetTheme.shape, isNull);
      expect(theme.floatingActionButtonTheme.shape, isNull);
      expect(theme.snackBarTheme.shape, isNull);
      expect(theme.navigationBarTheme.indicatorShape, isNull);
      expect(theme.segmentedButtonTheme.style, isNull);
      expect(radiusOf(theme.cardTheme.shape), NavisRadius.mdAll);
      expect(theme.chipTheme.shape, isA<StadiumBorder>());
      expect(theme.extension<NavisTokens>()!.panelRadius, 20);
    });

    test('soft and square thread the table into component themes', () {
      for (final entry in <NavisCornerStyle, NavisShapeData>{
        NavisCornerStyle.soft: NavisShapeData.soft,
        NavisCornerStyle.square: NavisShapeData.square,
      }.entries) {
        for (final theme in <ThemeData>[
          buildLightTheme(_seed, corners: entry.key),
          buildDarkTheme(_seed, corners: entry.key),
          buildOledTheme(_seed, corners: entry.key),
        ]) {
          final data = entry.value;
          expect(theme.extension<NavisShapeData>()!.style, entry.key);
          expect(radiusOf(theme.cardTheme.shape), data.mdAll);
          expect(radiusOf(theme.dialogTheme.shape), data.xlAll);
          expect(radiusOf(theme.bottomSheetTheme.shape), data.sheetTop);
          expect(radiusOf(theme.popupMenuTheme.shape), data.mdAll);
          expect(radiusOf(theme.snackBarTheme.shape), data.smAll);
          expect(radiusOf(theme.floatingActionButtonTheme.shape), data.lgAll);
          expect(theme.chipTheme.shape, data.controlShape);
          expect(theme.navigationBarTheme.indicatorShape, data.controlShape);
          expect(theme.navigationRailTheme.indicatorShape, data.controlShape);
          expect(
            (theme.inputDecorationTheme.border! as OutlineInputBorder)
                .borderRadius,
            data.mdAll,
          );
          expect(
            theme.segmentedButtonTheme.style!.shape!.resolve(<WidgetState>{}),
            data.controlShape,
          );
          expect(
            theme.outlinedButtonTheme.style!.shape!.resolve(<WidgetState>{}),
            data.controlShape,
          );
          expect(theme.extension<NavisTokens>()!.panelRadius, data.xl);
          expect(theme.extension<NavisTokens>()!.cardRadius, data.lg);
        }
      }
    });
  });

  test('cornerStyleProvider defaults to rounded and can be set', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(cornerStyleProvider), NavisCornerStyle.rounded);
    container.read(cornerStyleProvider.notifier).set(NavisCornerStyle.square);
    expect(container.read(cornerStyleProvider), NavisCornerStyle.square);
  });

  testWidgets('HomeNoticeCard follows the corner style', (tester) async {
    for (final entry in <NavisCornerStyle, double>{
      NavisCornerStyle.rounded: 16,
      NavisCornerStyle.soft: 24,
      NavisCornerStyle.square: 4,
    }.entries) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(_seed, corners: entry.key),
          home: Scaffold(
            body: HomeNoticeCard(
              openKey: const ValueKey<String>('open'),
              dismissKey: const ValueKey<String>('dismiss'),
              title: 'Title',
              dismissTooltip: 'Dismiss',
              onOpen: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      // The theme change animates; settle on the target style.
      await tester.pumpAndSettle();
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(HomeNoticeCard),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.borderRadius, BorderRadius.circular(entry.value));
    }
  });
}
