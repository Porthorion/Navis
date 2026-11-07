import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/navis_refresh_indicator.dart';

import '../../helpers/haptics_spy.dart';

void main() {
  late HapticsSpy spy;
  var refreshes = 0;
  Future<void> Function() onRefresh = () async {};

  // The viewport is 600 px tall, so letting go after pulling 150 px
  // (a quarter of it) refreshes: each 15 px below is a tenth of the way.
  Future<void> pumpList(WidgetTester tester, {double scrolled = 0}) async {
    spy = HapticsSpy.install(tester);
    refreshes = 0;
    onRefresh = () async => refreshes++;
    final controller = ScrollController(initialScrollOffset: scrolled);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NavisRefreshIndicator(
            onRefresh: () => onRefresh(),
            child: ListView.builder(
              controller: controller,
              itemCount: 40,
              itemBuilder: (_, i) => SizedBox(height: 56, child: Text('$i')),
            ),
          ),
        ),
      ),
    );
  }

  Future<TestGesture> startPull(WidgetTester tester) async {
    final gesture = await tester.startGesture(const Offset(200, 200));
    // Past the drag slop, so the following moves count in full.
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    return gesture;
  }

  Future<void> pullTo(
    WidgetTester tester,
    TestGesture gesture,
    double from,
    double to,
  ) async {
    // 5 px at a time, like a finger, so every mark is seen.
    final step = to > from ? 5.0 : -5.0;
    for (var y = from; (to - y).abs() >= 5; y += step) {
      await gesture.moveBy(Offset(0, step));
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('a full pull ticks at each quarter, firms at the trigger and '
      'confirms when the refresh finishes', (tester) async {
    await pumpList(tester);
    final gesture = await startPull(tester);
    await pullTo(tester, gesture, 0, 190);
    expect(await spy.take(tester), [
      'frequentTick',
      'frequentTick',
      'frequentTick',
      'thresholdOn',
    ]);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    expect(await spy.take(tester), ['confirm']);
  });

  testWidgets('hovering at the trigger point does not repeat', (tester) async {
    await pumpList(tester);
    final gesture = await startPull(tester);
    await pullTo(tester, gesture, 0, 155);
    spy.kinds.clear();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, i.isEven ? 3 : -3));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(await spy.take(tester), isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('pulling back below the trigger says so once', (tester) async {
    await pumpList(tester);
    final gesture = await startPull(tester);
    await pullTo(tester, gesture, 0, 170);
    spy.kinds.clear();
    await pullTo(tester, gesture, 170, 20);
    final kinds = await spy.take(tester);
    expect(kinds.first, 'thresholdOff');
    expect(kinds.where((k) => k == 'thresholdOff'), hasLength(1));
    expect(kinds.skip(1), everyElement('frequentTick'));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshes, 0);
  });

  testWidgets('a short pull ticks but never refreshes or confirms', (
    tester,
  ) async {
    await pumpList(tester);
    final gesture = await startPull(tester);
    await pullTo(tester, gesture, 0, 45);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshes, 0);
    expect(await spy.take(tester), ['frequentTick']);
  });

  testWidgets('dragging the list when it is not at the top is silent', (
    tester,
  ) async {
    await pumpList(tester, scrolled: 400);
    final gesture = await startPull(tester);
    await pullTo(tester, gesture, 0, 150);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshes, 0);
    expect(await spy.take(tester), isEmpty);
  });
}
