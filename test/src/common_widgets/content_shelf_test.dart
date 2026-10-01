import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/content_shelf.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/test_theme.dart';

void main() {
  Future<void> render(
    WidgetTester tester, {
    bool showNextTooltip = true,
  }) async {
    setAdaptiveTestViewport(tester, const Size(1000, 600));
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdaptiveContextScope(
          adaptiveContext: resolveAdaptiveContext(
            desktopRuntime: true,
            viewportSize: const Size(1000, 600),
            safePadding: EdgeInsets.zero,
          ),
          child: Scaffold(
            body: ContentShelf(
              itemCount: 30,
              extent: 148,
              height: 148,
              gap: 12,
              showNextTooltip: showNextTooltip,
              itemBuilder: (_, index) =>
                  ColoredBox(color: Colors.blue, child: Text('$index')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a mouse drag scrolls the shelf', (tester) async {
    await render(tester);
    final list = find.byType(Scrollable);
    double offset() =>
        tester.state<ScrollableState>(list.first).position.pixels;
    expect(offset(), 0);
    await tester.dragFrom(
      tester.getCenter(find.text('2')),
      const Offset(-300, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(offset(), greaterThan(250));
  });

  testWidgets('default Next tooltip appears on actual mouse hover', (
    tester,
  ) async {
    await render(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.chevron_right)));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Next items'), findsOneWidget);
  });

  testWidgets(
    'suppressed tooltip keeps one accessible name and mouse/keyboard paging',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await render(tester, showNextTooltip: false);
        final button = find.byIcon(Icons.chevron_right);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer();
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(button));
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.text('Next items'), findsNothing);
        expect(find.byTooltip('Next items'), findsNothing);
        expect(find.bySemanticsLabel('Next items'), findsOneWidget);
        expect(
          tester.getSemantics(find.bySemanticsLabel('Next items')),
          matchesSemantics(
            label: 'Next items',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
            hasFocusAction: true,
            isFocusable: true,
          ),
        );
        expect(
          tester
              .getSize(
                find.ancestor(of: button, matching: find.byType(IconButton)),
              )
              .width,
          greaterThanOrEqualTo(48),
        );
        final scrollable = tester.state<ScrollableState>(
          find.byType(Scrollable),
        );
        await tester.tap(button);
        await tester.pumpAndSettle();
        final afterClick = scrollable.position.pixels;
        expect(afterClick, greaterThan(0));
        expect(find.byTooltip('Previous items'), findsOneWidget);
        Focus.of(tester.element(button)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(scrollable.position.pixels, greaterThan(afterClick));
        expect(find.bySemanticsLabel('Next items'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
