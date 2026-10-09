import 'dart:async';

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
      expect(NavisTokens.defaults.panelRadius, NavisRadius.xl);
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
      expect(theme.iconButtonTheme.style, isNull);
      // Menus keep the 4 px shape Material renders today.
      expect(
        radiusOf(theme.menuTheme.style!.shape!.resolve(<WidgetState>{})),
        NavisRadius.xsAll,
      );
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
          expect(
            theme.iconButtonTheme.style!.shape!.resolve(<WidgetState>{}),
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
      final repository = container.read(settingsRepositoryProvider);
      for (final style in [NavisCornerStyle.soft, NavisCornerStyle.square]) {
        final updated = Completer<void>();
        final subscription = container.listen(cornerStyleProvider, (_, next) {
          if (next == style && !updated.isCompleted) updated.complete();
        });
        await repository.updateCornerStyle(style);
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
      expect(material.borderRadius, BorderRadius.circular(entry.value));
    }
  });
}
