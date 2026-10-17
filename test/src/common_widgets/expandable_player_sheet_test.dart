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
    this.onSwipeUp,
    this.removeBottomPadding = false,
    this.pageTaps,
  });

  final VoidCallback? onDragStart;
  final VoidCallback? onSwipeUp;

  /// When set, an opaque page sits behind the sheet and counts its taps.
  final ValueNotifier<int>? pageTaps;

  /// Like the shell's `_BottomNavInsetScope`, which removes the bottom padding
  /// the sheet would otherwise inherit from the system.
  final bool removeBottomPadding;
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
                child: Builder(
                  builder: (context) => _withPage(
                    _scoped(
                      context,
                      ExpandablePlayerSheet(
                        isExpanded: _expanded,
                        bottomInset: widget.bottomInset,
                        onDragStart: widget.onDragStart,
                        onSwipeUp: widget.onSwipeUp,
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
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _withPage(Widget sheet) {
    final taps = widget.pageTaps;
    if (taps == null) return sheet;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            key: const Key('page'),
            behavior: HitTestBehavior.opaque,
            onTap: () => taps.value += 1,
          ),
        ),
        sheet,
      ],
    );
  }

  Widget _scoped(BuildContext context, Widget child) =>
      widget.removeBottomPadding
      ? MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: child,
        )
      : child;
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
      expect(rig.collapseCalls.value, 1);
    });
  });

  group('mini player at the panel edge', () {
    Future<_Rig> pumpRig(
      WidgetTester tester, {
      ValueNotifier<int>? taps,
    }) async {
      final rig = _Rig();
      await tester.pumpWidget(
        _SheetHarness(
          expandCalls: rig.expandCalls,
          collapseCalls: rig.collapseCalls,
          progress: rig.progress,
          bottomInset: 80,
          pageTaps: taps,
        ),
      );
      await tester.pumpAndSettle();
      return rig;
    }

    double miniOpacity(WidgetTester tester) => tester
        .widget<Opacity>(
          find.ancestor(
            of: find.byKey(const Key('mini-player')),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;

    /// Drags the open mini player to [progress] and holds the finger there.
    Future<TestGesture> dragTo(
      WidgetTester tester,
      _Rig rig,
      double progress,
    ) async {
      final miniTop = tester
          .getTopLeft(find.byKey(const Key('mini-player')))
          .dy;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('mini-player'))),
      );
      await gesture.moveBy(Offset(0, -progress * miniTop));
      await tester.pump();
      expect(rig.progress.value, closeTo(progress, 0.01));
      return gesture;
    }

    testWidgets('at 5% it rides on top of the panel edge, still visible; '
        'by 15% it is gone and stops taking hits', (tester) async {
      final rig = await pumpRig(tester);
      final miniTop = tester.getTopLeft(find.byKey(const Key('mini-player')));
      final gesture = await dragTo(tester, rig, 0.05);

      final panelTop = tester
          .getTopLeft(find.byKey(const Key('full-player')))
          .dy;
      expect(
        tester.getTopLeft(find.byKey(const Key('mini-player'))).dy,
        closeTo(panelTop, 0.5),
        reason: 'moves with the panel edge',
      );
      expect(panelTop, lessThan(miniTop.dy));
      expect(miniOpacity(tester), inInclusiveRange(0.5, 0.95));
      final at = tester.getCenter(find.byKey(const Key('mini-player')));
      final targets = tester
          .hitTestOnBinding(at)
          .path
          .map((entry) => entry.target)
          .toList();
      expect(
        targets,
        contains(tester.renderObject(find.byKey(const Key('mini-player')))),
        reason: 'mini player takes the touch',
      );
      expect(
        tester.getRect(find.byKey(const Key('full-player'))).contains(at),
        isTrue,
        reason: 'the panel is under it, so it is painted above the panel',
      );
      expect(
        targets,
        isNot(
          contains(tester.renderObject(find.byKey(const Key('full-player')))),
        ),
      );

      await gesture.moveBy(Offset(0, -0.12 * miniTop.dy));
      await tester.pump();
      expect(rig.progress.value, greaterThanOrEqualTo(0.15));
      expect(miniOpacity(tester), 0);
      expect(
        find.descendant(
          of: find.byType(IgnorePointer),
          matching: find.byKey(const Key('mini-player')),
        ),
        findsWidgets,
      );
      final late = tester
          .hitTestOnBinding(at)
          .path
          .map((entry) => entry.target);
      expect(
        late,
        isNot(
          contains(tester.renderObject(find.byKey(const Key('mini-player')))),
        ),
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a collapse lands the panel with the mini player fading in on '
        'its edge, fully opaque at progress 0', (tester) async {
      final rig = await pumpRig(tester);
      await tester.tap(find.text('expand'));
      await tester.pumpAndSettle();
      expect(miniOpacity(tester), 0);

      await tester.tap(find.text('collapse'));
      final opacities = <double>[];
      for (var i = 0; i < 40 && rig.progress.value > 0; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        opacities.add(miniOpacity(tester));
        if (rig.progress.value > 0 && rig.progress.value < 0.15) {
          expect(
            tester.getTopLeft(find.byKey(const Key('mini-player'))).dy,
            closeTo(
              tester
                  .getTopLeft(
                    find.byKey(const Key('full-player'), skipOffstage: false),
                  )
                  .dy,
              0.5,
            ),
          );
        }
      }
      await tester.pumpAndSettle();
      expect(rig.progress.value, 0);
      expect(miniOpacity(tester), 1);
      expect(
        opacities.where((o) => o > 0 && o < 1),
        isNotEmpty,
        reason: 'fades in over the tail, no single-frame pop: $opacities',
      );
    });

    testWidgets('mid-settle, a tap above the panel top edge reaches the page', (
      tester,
    ) async {
      final taps = ValueNotifier<int>(0);
      final rig = await pumpRig(tester, taps: taps);
      final miniTop = tester.getTopLeft(find.byKey(const Key('mini-player')));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('mini-player'))),
      );
      await gesture.moveBy(Offset(0, -0.4 * miniTop.dy));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 16));
      expect(rig.progress.value, inExclusiveRange(0, 1));
      final edge = tester
          .getTopLeft(find.byKey(const Key('full-player'), skipOffstage: false))
          .dy;
      expect(edge, greaterThan(40));

      await tester.tapAt(Offset(200, edge - 20));
      expect(taps.value, 1, reason: 'above the edge is the page');
      await tester.tapAt(Offset(200, edge + 20));
      expect(taps.value, 1, reason: 'below the edge is the panel');
      await tester.pumpAndSettle();
    });
  });

  group('layering and release', () {
    testWidgets('mid-drag the panel covers the mini player and takes its hits', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(
        _SheetHarness(
          expandCalls: rig.expandCalls,
          collapseCalls: rig.collapseCalls,
          progress: rig.progress,
          bottomInset: 80,
        ),
      );
      await tester.pumpAndSettle();
      final miniCenter = tester.getCenter(find.byKey(const Key('mini-player')));

      final gesture = await tester.startGesture(miniCenter);
      await gesture.moveBy(const Offset(0, -150));
      await tester.pump();
      await gesture.up();
      // Released mid-travel: the settle is running and the panel is on its way.
      await tester.pump(const Duration(milliseconds: 16));
      expect(rig.progress.value, inExclusiveRange(0, 0.5));

      final hit = tester.hitTestOnBinding(miniCenter);
      final targets = hit.path.map((entry) => entry.target).toList();
      expect(
        targets,
        contains(tester.renderObject(find.byKey(const Key('full-player')))),
        reason: 'the panel is on top of the mini player',
      );
      expect(
        targets,
        isNot(
          contains(tester.renderObject(find.byKey(const Key('mini-player')))),
        ),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('a fast fling is not restarted when the parent mirrors the '
        'reported state back in', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(
        _SheetHarness(
          expandCalls: rig.expandCalls,
          collapseCalls: rig.collapseCalls,
          progress: rig.progress,
        ),
      );
      await tester.pumpAndSettle();

      await tester.fling(
        find.byKey(const Key('mini-player')),
        const Offset(0, -200),
        8000,
      );
      final samples = <double>[];
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        samples.add(rig.progress.value);
      }
      // The release flings at the 6x cap. Re-flinging at 2.5x when the parent
      // flips `isExpanded` slows it: the third frame is at ~0.55 instead of
      // ~0.60.
      expect(samples[2], greaterThan(0.58), reason: 'samples: $samples');
      await tester.pumpAndSettle();
    });

    group('queue swipe guard', () {
      Future<int> swipeUpFrom(WidgetTester tester, double bottomGap) async {
        tester.view
          ..devicePixelRatio = 1
          ..padding = const FakeViewPadding(bottom: 100)
          ..viewPadding = const FakeViewPadding(bottom: 100);
        addTearDown(() {
          tester.view
            ..resetDevicePixelRatio()
            ..resetPadding()
            ..resetViewPadding();
        });
        var swipeUps = 0;
        final rig = _Rig();
        await tester.pumpWidget(
          _SheetHarness(
            expandCalls: rig.expandCalls,
            collapseCalls: rig.collapseCalls,
            progress: rig.progress,
            onSwipeUp: () => swipeUps++,
            removeBottomPadding: true,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('expand'));
        await tester.pumpAndSettle();

        final height = tester.view.physicalSize.height;
        await tester.flingFrom(
          Offset(100, height - bottomGap),
          const Offset(0, -150),
          2000,
        );
        await tester.pumpAndSettle();
        return swipeUps;
      }

      testWidgets('is lengthened by the system inset the shell scope removes', (
        tester,
      ) async {
        // 150 px above the screen bottom: outside the 120 px base guard, but
        // inside it once the 100 px system inset is added.
        expect(await swipeUpFrom(tester, 150), 0);
      });

      testWidgets('lets a swipe from higher up open the queue', (tester) async {
        expect(await swipeUpFrom(tester, 300), 1);
      });
    });
  });
}

class _Rig {
  final expandCalls = ValueNotifier<int>(0);
  final collapseCalls = ValueNotifier<int>(0);
  final progress = ValueNotifier<double>(0);
}
