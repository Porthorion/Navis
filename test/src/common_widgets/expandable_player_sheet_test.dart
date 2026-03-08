import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/expandable_player_sheet.dart';

class _SheetHarness extends StatefulWidget {
  const _SheetHarness({
    required this.expandCalls,
    required this.collapseCalls,
    required this.progress,
  });

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
                child: ExpandablePlayerSheet(
                  isExpanded: _expanded,
                  onExpand: () {
                    widget.expandCalls.value += 1;
                  },
                  onCollapse: () {
                    widget.collapseCalls.value += 1;
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
}
