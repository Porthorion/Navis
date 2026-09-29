import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/navis_tooltip.dart';

const _bubbleKey = ValueKey<String>('tooltip-test-bubble');

void main() {
  for (final preserveTargetNode in <bool>[false, true]) {
    testWidgets(
      'excluded nested tooltip keeps semantics valid (target node: $preserveTargetNode)',
      (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              tooltipTheme: const TooltipThemeData(
                waitDuration: Duration.zero,
                exitDuration: Duration.zero,
              ),
            ),
            home: Scaffold(
              body: Dialog(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tooltip(
                      message: 'Sibling',
                      child: Semantics(
                        explicitChildNodes: true,
                        child: const Text('Sibling'),
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      height: 100,
                      child: Overlay.wrap(
                        child: preserveTargetNode
                            ? Semantics(
                                container: true,
                                label: 'Player action',
                                excludeSemantics: true,
                                child: const NavisTooltip(
                                  message: 'Nested tooltip',
                                  bubbleKey: _bubbleKey,
                                  child: Text('Hover target'),
                                ),
                              )
                            : const ExcludeSemantics(
                                child: NavisTooltip(
                                  message: 'Nested tooltip',
                                  bubbleKey: _bubbleKey,
                                  child: Text('Hover target'),
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final outside =
            tester.getBottomRight(find.byType(Scaffold)) - const Offset(4, 4);
        for (var cycle = 0; cycle < 3; cycle++) {
          await mouse.moveTo(tester.getCenter(find.text('Hover target')));
          await tester.pumpAndSettle();
          expect(find.byKey(_bubbleKey), findsOneWidget);
          await mouse.moveTo(outside);
          await tester.pumpAndSettle();
          expect(find.byKey(_bubbleKey), findsNothing);
          expect(tester.takeException(), isNull);
        }
        await mouse.removePointer();
        semantics.dispose();
      },
    );
  }

  testWidgets('long press and removing the owner clean up the tooltip', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: NavisTooltip(
              message: 'Action explanation',
              bubbleKey: _bubbleKey,
              child: Icon(Icons.info),
            ),
          ),
        ),
      ),
    );
    final target = find.byType(NavisTooltip);
    final node = tester.getSemantics(target);
    expect(node.tooltip, 'Action explanation');
    await tester.longPress(target);
    await tester.pump();
    expect(find.byKey(_bubbleKey), findsOneWidget);
    expect(tester.getSemantics(target).id, node.id);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(find.byKey(_bubbleKey), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
