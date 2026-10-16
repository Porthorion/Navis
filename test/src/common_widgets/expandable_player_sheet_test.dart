import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/expandable_player_sheet.dart';

import '../../helpers/test_theme.dart';

class _SheetHarness extends StatefulWidget {
  const new({
    required this.expandCalls,
    required this.collapseCalls,
    required this.progress,
    this.bottomInset = 0,
    this.onDragStart,
  });

  final VoidCallback? onDragStart;
  final double bottomInset;
  final ValueNotifier<int> expandCalls;
  final ValueNotifier<int> collapseCalls;
  final ValueNotifier<double> progress;

  @override
  State<_SheetHarness> createState() => _SheetHarnessState();
}

class _SheetHarnessState extends State<_SheetHarness> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: testTheme(),
      home: Scaffold(
        body: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                TextButton(
                  onPressed: () => setState(() => _expanded = true),
                  child: const Text('expand'),
                ),
                TextButton(
                  onPressed: () => setState(() => _expanded = false),
                  child: const Text('collapse'),
                ),
              ],
            ),
            Expanded(
              child: SizedBox.expand(
                key: const Key('sheet-area'),
                child: ExpandablePlayerSheet(
                  isExpanded: _expanded,
                  bottomInset: widget.bottomInset,
                  onDragStart: widget.onDragStart,
                  // Like the shell, mirror the reported state back in.
                  onExpand: () {
                    widget.expandCalls.value += 1;
                    setState(() => _expanded = true);
                  },
                  onCollapse: () {
                    widget.collapseCalls.value += 1;
                    setState(() => _expanded = false);
                  },
                  onProgressChanged: (value) {
                    widget.progress.value = value;
                  },
                  miniPlayer: const SizedBox(
                    key: Key('mini-player'),
                    height: ExpandablePlayerSheet.miniPlayerHeight,
                    child: Text('Mini Player'),
                  ),
                  fullPlayer: const SizedBox(
                    key: Key('full-player'),
                    child: Text('Full Player'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets('animates expand and collapse lifecycle', (tester) async {
    final expandCalls = ValueNotifier<int>(0);
    final collapseCalls = ValueNotifier<int>(0);
    final progress = ValueNotifier<double>(0);

    await tester.pumpWidget(
      _SheetHarness(
        expandCalls: expandCalls,
        collapseCalls: collapseCalls,
        progress: progress,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mini-player')), findsOneWidget);

    await tester.tap(find.text('expand'));
    await tester.pumpAndSettle();

    expect(progress.value, closeTo(1, 0.01));
    // Mini player stays in the tree but is hidden via Opacity(0) when expanded.
    expect(find.byKey(const Key('mini-player')), findsOneWidget);
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(
              of: find.byKey(const Key('mini-player')),
              matching: find.byType(Opacity),
            ),
          )
          .opacity,
      closeTo(0, 0.01),
    );

    await tester.tap(find.text('collapse'));
    await tester.pumpAndSettle();

    expect(progress.value, closeTo(0, 0.01));
    expect(find.byKey(const Key('mini-player')), findsOneWidget);
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(
              of: find.byKey(const Key('mini-player')),
              matching: find.byType(Opacity),
            ),
          )
          .opacity,
      closeTo(1, 0.01),
    );
  });

  testWidgets('fling up expands and fling down collapses', (tester) async {
    final expandCalls = ValueNotifier<int>(0);
    final collapseCalls = ValueNotifier<int>(0);
    final progress = ValueNotifier<double>(0);

    await tester.pumpWidget(
      _SheetHarness(
        expandCalls: expandCalls,
        collapseCalls: collapseCalls,
        progress: progress,
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.byKey(const Key('mini-player')),
      const Offset(0, -600),
      1200,
    );
    await tester.pumpAndSettle();

    expect(progress.value, closeTo(1, 0.01));

    await tester.fling(
      find.byKey(const Key('full-player')),
      const Offset(0, 600),
      1200,
    );
    await tester.pumpAndSettle();

    expect(progress.value, closeTo(0, 0.01));
  });

  testWidgets('switches player surfaces immediately for reduced motion', (
    tester,
  ) async {
    final expandCalls = ValueNotifier<int>(0);
    final collapseCalls = ValueNotifier<int>(0);
    final progress = ValueNotifier<double>(0);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _SheetHarness(
          expandCalls: expandCalls,
          collapseCalls: collapseCalls,
          progress: progress,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('expand'));
    await tester.pump();
    expect(progress.value, 1);

    await tester.tap(find.text('collapse'));
    await tester.pump();
    expect(progress.value, 0);
  });

  group('drag tracking', () {
    Future<_Rig> pumpRig(WidgetTester tester, {double bottomInset = 0}) async {
      final rig = _Rig();
      await tester.pumpWidget(
        _SheetHarness(
          expandCalls: rig.expandCalls,
          collapseCalls: rig.collapseCalls,
          progress: rig.progress,
          bottomInset: bottomInset,
        ),
      );
      await tester.pumpAndSettle();
      return rig;
    }

    double panelTop(WidgetTester tester) => tester
        .getTopLeft(find.byKey(const Key('full-player'), skipOffstage: false))
        .dy;

    testWidgets('full player is hidden while collapsed', (tester) async {
      await pumpRig(tester);

      expect(find.byKey(const Key('full-player')), findsNothing);
      expect(
        find.byKey(const Key('full-player'), skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('panel top starts at the mini player top and tracks the '
        'finger 1:1, including the touch slop', (tester) async {
      await pumpRig(tester, bottomInset: 80);
      final miniTop = tester.getTopLeft(find.byKey(const Key('mini-player')));
      final sheetBottom = tester
          .getBottomLeft(find.byKey(const Key('sheet-area')))
          .dy;
      expect(miniTop.dy, closeTo(sheetBottom - 80 - 64, 0.5));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('mini-player'))),
      );
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      expect(panelTop(tester), closeTo(miniTop.dy - 100, 0.5));

      await gesture.moveBy(const Offset(0, -50));
      await tester.pump();
      expect(panelTop(tester), closeTo(miniTop.dy - 150, 0.5));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('panel top follows a downward drag from the expanded sheet', (
      tester,
    ) async {
      await pumpRig(tester);
      await tester.tap(find.text('expand'));
      await tester.pumpAndSettle();
      expect(
        panelTop(tester),
        closeTo(tester.getTopLeft(find.byKey(const Key('sheet-area'))).dy, 0.5),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('full-player'))),
      );
      final top = panelTop(tester);
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      expect(panelTop(tester), closeTo(top + 120, 0.5));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('onExpand and onCollapse fire at drag release, before the '
        'settle animation finishes', (tester) async {
      final rig = await pumpRig(tester);

      final up = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('mini-player'))),
      );
      await up.moveBy(const Offset(0, -150));
      await up.moveBy(const Offset(0, -150));
      await tester.pump(const Duration(milliseconds: 16));
      expect(rig.expandCalls.value, 0, reason: 'not while dragging');
      await up.up();
      await tester.pump(const Duration(milliseconds: 16));
      expect(rig.progress.value, inExclusiveRange(0, 1));
      expect(rig.expandCalls.value, 1, reason: 'reported at release');

      await tester.pumpAndSettle();
      expect(rig.progress.value, closeTo(1, 0.01));
      expect(rig.expandCalls.value, 1);

      final down = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('full-player'))),
      );
      await down.moveBy(const Offset(0, 150));
      await down.moveBy(const Offset(0, 150));
      await tester.pump(const Duration(milliseconds: 16));
      expect(rig.collapseCalls.value, 0, reason: 'not while dragging');
      await down.up();
      await tester.pump(const Duration(milliseconds: 16));
      expect(rig.progress.value, inExclusiveRange(0, 1));
      expect(rig.collapseCalls.value, 1, reason: 'reported at release');

      await tester.pumpAndSettle();
      expect(rig.progress.value, closeTo(0, 0.01));
      expect(rig.collapseCalls.value, 1);
      expect(rig.expandCalls.value, 1);
    });

    testWidgets('onDragStart fires once per drag, before any callback', (
      tester,
    ) async {
      final rig = _Rig();
      var dragStarts = 0;
      await tester.pumpWidget(
        _SheetHarness(
          expandCalls: rig.expandCalls,
          collapseCalls: rig.collapseCalls,
          progress: rig.progress,
          onDragStart: () => dragStarts++,
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('mini-player'))),
      );
      await gesture.moveBy(const Offset(0, -100));
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      expect(dragStarts, 1);
      expect(rig.expandCalls.value, 0);

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a short drag snaps back without calling onExpand', (
      tester,
    ) async {
      final rig = await pumpRig(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('mini-player'))),
      );
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(rig.progress.value, 0);
      expect(rig.expandCalls.value, 0);
    });

    testWidgets('reduced motion jumps to the target on release and reports '
        'it', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _SheetHarness(
            expandCalls: rig.expandCalls,
            collapseCalls: rig.collapseCalls,
            progress: rig.progress,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final up = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('mini-player'))),
      );
      await up.moveBy(const Offset(0, -300));
      await up.up();
      await tester.pump();
      expect(rig.progress.value, 1);
      expect(rig.expandCalls.value, 1);
      expect(find.byKey(const Key('full-player')), findsOneWidget);

      final down = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('full-player'))),
      );
      await down.moveBy(const Offset(0, 300));
      await down.up();
      await tester.pump();
      expect(rig.progress.value, 0);
    });
  });
}

class _Rig {
  final expandCalls = ValueNotifier<int>(0);
  final collapseCalls = ValueNotifier<int>(0);
  final progress = ValueNotifier<double>(0);
}
