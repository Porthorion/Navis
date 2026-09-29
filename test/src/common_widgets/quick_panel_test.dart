import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/quick_panel.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../helpers/adaptive_test_harness.dart';

void main() {
  Future<void> pumpHost(
    WidgetTester tester, {
    required bool desktop,
    int items = 40,
    bool reduceMotion = false,
    Alignment anchorAlignment = Alignment.bottomCenter,
  }) async {
    setAdaptiveTestViewport(
      tester,
      desktop ? const Size(1280, 800) : const Size(390, 844),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion),
          child: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: desktop,
              viewportSize: MediaQuery.sizeOf(context),
              safePadding: EdgeInsets.zero,
            ),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: Align(
            alignment: anchorAlignment,
            child: Builder(
              builder: (anchorContext) => IconButton(
                key: const ValueKey('anchor'),
                onPressed: () => showQuickPanel(
                  anchorContext,
                  title: 'Speed & Pitch',
                  subtitleBuilder: (_) => const Text('1.25× · +3.86 st'),
                  headerTrailingBuilder: (_) =>
                      Switch(value: true, onChanged: (_) {}),
                  bodyBuilder: (_) => Column(
                    children: [
                      for (var i = 0; i < items; i++)
                        SizedBox(height: 40, child: Text('Row $i')),
                    ],
                  ),
                  footerBuilder: (_) => TextButton(
                    onPressed: () {},
                    child: const Text('Reset'),
                  ),
                ),
                icon: const Icon(Icons.speed),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('anchor')));
    await tester.pumpAndSettle();
  }

  testWidgets('header and footer stay pinned while only the body scrolls', (
    tester,
  ) async {
    await pumpHost(tester, desktop: true);
    await open(tester);
    final titleTop = tester.getTopLeft(find.text('Speed & Pitch')).dy;
    final footerTop = tester.getTopLeft(find.text('Reset')).dy;
    await tester.drag(
      find.byKey(const ValueKey('quickPanelBody')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Speed & Pitch')).dy, titleTop);
    expect(tester.getTopLeft(find.text('Reset')).dy, footerTop);
    expect(find.text('1.25× · +3.86 st'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('desktop popover sits above its anchor with a pointing tail', (
    tester,
  ) async {
    await pumpHost(tester, desktop: true);
    await open(tester);
    final card = tester.getRect(
      find.byKey(const ValueKey('desktopAnchoredPopover')),
    );
    final anchor = tester.getRect(find.byKey(const ValueKey('anchor')));
    expect(card.bottom, lessThan(anchor.top));
    expect(card.height, lessThanOrEqualTo(640));
    final tail = find.descendant(
      of: find.byType(CustomMultiChildLayout),
      matching: find.byType(CustomPaint),
    );
    final tailRect = tester.getRect(tail.last);
    expect(tailRect.top, closeTo(card.bottom - 1, 0.01));
    expect(tailRect.center.dx, closeTo(anchor.center.dx, 0.5));
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('clicking the anchor again closes the popover', (tester) async {
    await pumpHost(tester, desktop: true);
    await open(tester);
    expect(find.byType(QuickPanelScaffold), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('anchor'))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(QuickPanelScaffold), findsNothing);
  });

  testWidgets('Escape and the close button dismiss the popover', (
    tester,
  ) async {
    await pumpHost(tester, desktop: true);
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(QuickPanelScaffold), findsNothing);
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('quickPanelClose')));
    await tester.pumpAndSettle();
    expect(find.byType(QuickPanelScaffold), findsNothing);
  });

  testWidgets('touch layouts use a content-sized sheet', (tester) async {
    await pumpHost(tester, desktop: false, items: 2);
    await open(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('desktopAnchoredPopover')), findsNothing);
    expect(
      tester.getSize(find.byType(QuickPanelScaffold)).height,
      lessThan(844 * 0.5),
    );
  });

  testWidgets('long sheets cap at 88 percent of the screen', (tester) async {
    await pumpHost(tester, desktop: false);
    await open(tester);
    expect(
      tester.getSize(find.byType(BottomSheet)).height,
      lessThanOrEqualTo(844 * 0.88 + 0.01),
    );
    expect(find.text('Reset'), findsOneWidget);
  });

  testWidgets('edge fade appears only in the direction with more content', (
    tester,
  ) async {
    await pumpHost(tester, desktop: true);
    await open(tester);
    ScrollEdgeFadeState fade() =>
        tester.state<ScrollEdgeFadeState>(find.byType(ScrollEdgeFade));
    expect(fade().fadesLeading, isFalse);
    expect(fade().fadesTrailing, isTrue);
    await tester.drag(
      find.byKey(const ValueKey('quickPanelBody')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(fade().fadesLeading, isTrue);
    expect(fade().fadesTrailing, isTrue);
  });

  testWidgets('short content has no fade and reduced motion opens instantly', (
    tester,
  ) async {
    await pumpHost(tester, desktop: true, items: 2, reduceMotion: true);
    await tester.tap(find.byKey(const ValueKey('anchor')));
    await tester.pump();
    expect(find.byType(QuickPanelScaffold), findsOneWidget);
    await tester.pump();
    final fade = tester.state<ScrollEdgeFadeState>(
      find.byType(ScrollEdgeFade),
    );
    expect(fade.fadesLeading, isFalse);
    expect(fade.fadesTrailing, isFalse);
  });
}
