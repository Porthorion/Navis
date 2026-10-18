import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/home_notice_card.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/corner_style_provider.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/theme/navis_tokens.dart';

import '../../helpers/test_database.dart';

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
      expect(
        NavisShapeData.forStyle(NavisCornerStyle.rounded).xl,
        NavisRadius.xl,
      );
    });

    test('soft is larger and softer with 14 px rectangular controls', () {
      final data = NavisShapeData.forStyle(NavisCornerStyle.soft);
      expect(
        <double>[data.xs, data.sm, data.md, data.lg, data.xl],
        <double>[6, 12, 18, 24, 32],
      );
      expect(data.control, 14);
      expect(data.controlShape, isNot(isA<StadiumBorder>()));
      expect(
        data.controlShape,
        isNot(NavisShapeData.rounded.controlShape),
        reason: 'Soft must read differently from Rounded',
      );
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

    test('pill sets explicit shapes equal to the Material defaults', () {
      final theme = buildDarkTheme(_seed);
      RoundedRectangleBorder? rrect(ShapeBorder? shape) =>
          shape as RoundedRectangleBorder?;
      ShapeBorder? resolved(ButtonStyle? style) =>
          style!.shape!.resolve(<WidgetState>{});
      expect(radiusOf(theme.dialogTheme.shape), BorderRadius.circular(28));
      expect(
        rrect(theme.bottomSheetTheme.shape)!.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(28)),
      );
      // A circle on a square FAB (the Material default is 16 px).
      expect(theme.floatingActionButtonTheme.shape, isA<StadiumBorder>());
      expect(theme.snackBarTheme.shape, isNull);
      expect(theme.navigationBarTheme.indicatorShape, isA<StadiumBorder>());
      expect(theme.navigationRailTheme.indicatorShape, isA<StadiumBorder>());
      expect(resolved(theme.segmentedButtonTheme.style), isA<StadiumBorder>());
      for (final style in <ButtonStyle?>[
        theme.outlinedButtonTheme.style,
        theme.filledButtonTheme.style,
        theme.textButtonTheme.style,
        theme.elevatedButtonTheme.style,
        theme.iconButtonTheme.style,
      ]) {
        expect(resolved(style), isA<StadiumBorder>());
      }
      expect(radiusOf(theme.cardTheme.shape), NavisRadius.mdAll);
      expect(theme.chipTheme.shape, isA<StadiumBorder>());
      expect(theme.extension<NavisShapeData>()!.xl, 20);
      // Menus keep the 4 px shape Material renders today.
      expect(
        radiusOf(theme.menuTheme.style!.shape!.resolve(<WidgetState>{})),
        NavisRadius.xsAll,
      );
    });

    test('every style sets every shape so theme switches never lerp null', () {
      for (final style in NavisCornerStyle.values) {
        final theme = buildLightTheme(_seed, corners: style);
        expect(theme.dialogTheme.shape, isNotNull, reason: '$style');
        expect(theme.bottomSheetTheme.shape, isNotNull, reason: '$style');
        expect(theme.floatingActionButtonTheme.shape, isNotNull);
        expect(theme.navigationBarTheme.indicatorShape, isNotNull);
        expect(theme.navigationRailTheme.indicatorShape, isNotNull);
        for (final button in <ButtonStyle?>[
          theme.outlinedButtonTheme.style,
          theme.filledButtonTheme.style,
          theme.textButtonTheme.style,
          theme.elevatedButtonTheme.style,
          theme.iconButtonTheme.style,
          theme.segmentedButtonTheme.style,
        ]) {
          expect(button?.shape, isNotNull, reason: '$style');
        }
      }
    });

    test('lerping between styles keeps buttons rounded in between', () {
      double radius(ShapeBorder? shape, Rect rect) {
        final path = shape!.getOuterPath(rect);
        // Sample the top-left corner: a point on the left edge near the top.
        // The distance the outline is inset from the corner grows with radius.
        var inset = 0.0;
        while (inset < rect.height / 2 && !path.contains(Offset(0.5, inset))) {
          inset += 0.25;
        }
        return inset;
      }

      const rect = Rect.fromLTWH(0, 0, 120, 40);
      for (final from in NavisCornerStyle.values) {
        for (final to in NavisCornerStyle.values) {
          if (from == to) continue;
          final a = buildLightTheme(_seed, corners: from);
          final b = buildLightTheme(_seed, corners: to);
          final before = radius(
            a.filledButtonTheme.style!.shape!.resolve(<WidgetState>{}),
            rect,
          );
          final after = radius(
            b.filledButtonTheme.style!.shape!.resolve(<WidgetState>{}),
            rect,
          );
          for (final t in <double>[0.25, 0.5, 0.75]) {
            final mid = ThemeData.lerp(a, b, t);
            final shape = mid.filledButtonTheme.style!.shape!.resolve(
              <WidgetState>{},
            );
            // Flutter's intermediate Stadium<->RoundedRectangle shapes are
            // private classes; what matters is that the outline stays
            // rounded between the endpoints, never square.
            expect(shape, isA<OutlinedBorder>(), reason: '$from -> $to at $t');
            final inset = radius(shape, rect);
            expect(
              inset,
              inInclusiveRange(
                math.min(before, after) - 0.5,
                math.max(before, after) + 0.5,
              ),
              reason: '$from -> $to at $t',
            );
          }
          final midShape = ThemeData.lerp(a, b, 0.5);
          expect(midShape.dialogTheme.shape, isA<RoundedRectangleBorder>());
          expect(
            midShape.bottomSheetTheme.shape,
            isA<RoundedRectangleBorder>(),
          );
        }
      }
    });

    test(
      'shape data lerp interpolates radii and scaled() instead of flipping',
      () {
        final mid = NavisShapeData.rounded.lerp(NavisShapeData.soft, 0.5);
        expect(
          mid.md,
          (NavisShapeData.rounded.md + NavisShapeData.soft.md) / 2,
        );
        expect(mid.scaled(20), 25);
        expect(
          NavisShapeData.soft.lerp(NavisShapeData.square, 0.5).scaled(20),
          closeTo((30 + 5) / 2, 0.001),
        );
        expect(
          NavisShapeData.rounded.lerp(NavisShapeData.soft, 0).scaled(20),
          20,
        );
        expect(
          NavisShapeData.rounded.lerp(NavisShapeData.soft, 1).scaled(20),
          30,
        );
      },
    );

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
          expect(theme.extension<NavisShapeData>()!.xl, data.xl);
          expect(
            theme.iconButtonTheme.style!.shape!.resolve(<WidgetState>{}),
            data.controlShape,
          );
          expect(
            theme.filledButtonTheme.style!.shape!.resolve(<WidgetState>{}),
            data.controlShape,
          );
          expect(
            radiusOf(theme.menuTheme.style!.shape!.resolve(<WidgetState>{})),
            data.mdAll,
          );
        }
      }
    });
  });

  group('icon buttons', () {
    Future<void> pump(WidgetTester tester, NavisCornerStyle corners) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(_seed, corners: corners),
          home: Scaffold(
            body: Row(
              children: <Widget>[
                IconButton.filledTonal(
                  key: const ValueKey<String>('plain'),
                  onPressed: () {},
                  icon: const Icon(Icons.favorite),
                ),
                IconButton.filled(
                  key: const ValueKey<String>('round'),
                  style: NavisShapeData.circularIconButtonStyle,
                  onPressed: () {},
                  icon: const Icon(Icons.play_arrow),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    ShapeBorder? shapeOf(WidgetTester tester, String key) {
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(ValueKey<String>(key)),
              matching: find.byType(Material),
            )
            .first,
      );
      return material.shape;
    }

    testWidgets('plain icon buttons follow the style, play stays circular', (
      tester,
    ) async {
      await pump(tester, NavisCornerStyle.rounded);
      expect(shapeOf(tester, 'plain'), isA<StadiumBorder>());
      expect(shapeOf(tester, 'round'), isA<CircleBorder>());

      await pump(tester, NavisCornerStyle.soft);
      expect(shapeOf(tester, 'plain'), NavisShapeData.soft.controlShape);
      expect(shapeOf(tester, 'plain'), isNot(isA<StadiumBorder>()));
      expect(shapeOf(tester, 'round'), isA<CircleBorder>());

      await pump(tester, NavisCornerStyle.square);
      expect(shapeOf(tester, 'plain'), NavisShapeData.square.controlShape);
      expect(shapeOf(tester, 'round'), isA<CircleBorder>());
    });
  });

  group('cornerStyleProvider', () {
    for (final failed in [false, true]) {
      test(
        'defaults to rounded while settings ${failed ? 'fail' : 'load'}',
        () async {
          final controller = StreamController<AppSettingsModel>();
          addTearDown(controller.close);
          final container = ProviderContainer(
            retry: (_, _) => null,
            overrides: [
              appSettingsProvider.overrideWith((ref) => controller.stream),
            ],
          );
          addTearDown(container.dispose);
          container.listen(appSettingsProvider, (_, _) {});
          if (failed) {
            final expectation = expectLater(
              container.read(appSettingsProvider.future),
              throwsStateError,
            );
            controller.addError(StateError('fixture'));
            await expectation;
          }
          expect(container.read(cornerStyleProvider), NavisCornerStyle.rounded);
        },
      );
    }

    test('reflects every style and subsequent settings updates', () async {
      final controller = StreamController<AppSettingsModel>();
      addTearDown(controller.close);
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith((ref) => controller.stream),
        ],
      );
      addTearDown(container.dispose);
      container.listen(cornerStyleProvider, (_, _) {});
      for (final style in NavisCornerStyle.values) {
        final updated = Completer<void>();
        final subscription = container.listen(appSettingsProvider, (_, next) {
          next.whenData((settings) {
            if (settings.cornerStyle == style && !updated.isCompleted) {
              updated.complete();
            }
          });
        });
        controller.add(
          const AppSettingsModel.defaults().copyWith(cornerStyle: style),
        );
        await updated.future;
        subscription.close();
        expect(container.read(cornerStyleProvider), style);
      }
    });

    test('repository persistence updates reach the provider', () async {
      final database = createTestDatabase();
      final container = ProviderContainer(
        overrides: withTestDatabase(database),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      container.listen(cornerStyleProvider, (_, _) {});
      await container.read(appSettingsProvider.future);
      for (final style in [NavisCornerStyle.soft, NavisCornerStyle.square]) {
        final updated = Completer<void>();
        final subscription = container.listen(cornerStyleProvider, (_, next) {
          if (next == style && !updated.isCompleted) updated.complete();
        });
        await database.appSettingsDao.updateCornerStyle(style.name);
        await updated.future;
        subscription.close();
        expect(container.read(cornerStyleProvider), style);
      }
    }, skip: !sqliteAvailable);
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
      expect(
        (material.shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(entry.value),
      );
    }
  });
}
