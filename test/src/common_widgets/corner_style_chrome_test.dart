import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_theme.dart';

const Color _seed = Color(0xFF009688);

Future<void> _pump(
  WidgetTester tester,
  NavisCornerStyle style,
  Widget body,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildDarkTheme(_seed, corners: style),
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: body),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

BorderRadius _decorationRadius(WidgetTester tester, Finder within) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: within, matching: find.byType(DecoratedBox)).first,
  );
  return (box.decoration as BoxDecoration).borderRadius! as BorderRadius;
}

void main() {
  testWidgets(
    'NewFeatureTag badge is a pill, then a 14 px, then a 4 px rectangle',
    (tester) async {
      final radii = <NavisCornerStyle, double>{};
      for (final style in NavisCornerStyle.values) {
        await _pump(tester, style, const NewFeatureTag());
        radii[style] = _decorationRadius(
          tester,
          find.byType(NewFeatureTag),
        ).topLeft.x;
      }
      expect(radii[NavisCornerStyle.rounded], 999);
      expect(radii[NavisCornerStyle.soft], 14);
      expect(radii[NavisCornerStyle.square], 4);
    },
  );

  testWidgets('error notice shares the pill and follows the corner style', (
    tester,
  ) async {
    final radii = <NavisCornerStyle, double>{};
    for (final style in NavisCornerStyle.values) {
      final controller = AppNoticeController()
        ..show(message: 'Boom', level: AppNoticeLevel.error);
      addTearDown(controller.dispose);
      await _pump(tester, style, AppNoticeHost(controller: controller));
      await tester.pump(const Duration(seconds: 1));
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(AppNoticeHost),
              matching: find.byType(Material),
            )
            .first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      radii[style] = (shape.borderRadius as BorderRadius).topLeft.x;
    }
    expect(radii[NavisCornerStyle.rounded], 999);
    expect(radii[NavisCornerStyle.soft], 14);
    expect(radii[NavisCornerStyle.square], 4);
  });

  testWidgets(
    'info notice is a pill, a 14 px rectangle under soft, 4 px under square',
    (tester) async {
      final radii = <NavisCornerStyle, double>{};
      for (final style in NavisCornerStyle.values) {
        final controller = AppNoticeController()..show(message: 'Saved');
        addTearDown(controller.dispose);
        await _pump(tester, style, AppNoticeHost(controller: controller));
        await tester.pump(const Duration(seconds: 1));
        final material = tester.widget<Material>(
          find
              .descendant(
                of: find.byType(AppNoticeHost),
                matching: find.byType(Material),
              )
              .first,
        );
        radii[style] =
            ((material.shape! as RoundedRectangleBorder).borderRadius
                    as BorderRadius)
                .topLeft
                .x;
        controller.dismiss();
        await tester.pump(const Duration(seconds: 1));
      }
      expect(radii[NavisCornerStyle.rounded], 999);
      expect(radii[NavisCornerStyle.soft], 14);
      expect(radii[NavisCornerStyle.square], 4);
    },
  );

  testWidgets('circles stay circles under every corner style', (tester) async {
    for (final style in NavisCornerStyle.values) {
      await _pump(tester, style, const Center(child: CircleAvatar(radius: 20)));
      final box = tester.getSize(find.byType(CircleAvatar));
      expect(box, const Size(40, 40));
      final decorated = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byType(CircleAvatar),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      expect((decorated.decoration! as BoxDecoration).shape, BoxShape.circle);
    }
  });
}
