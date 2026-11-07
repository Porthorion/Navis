import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/navis_refresh_indicator.dart';

import '../../helpers/haptics_spy.dart';

import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';

void main() {
  late HapticsSpy spy;
  var refreshes = 0;
  Future<void> Function() onRefresh = () async {};

  // The viewport is 600 px tall, so letting go after pulling 150 px
  // (a quarter of it) refreshes: each 15 px below is a tenth of the way.
  Future<void> pumpList(
    WidgetTester tester, {
    double scrolled = 0,
    ScrollPhysics? physics,
  }) async {
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
              physics: physics,
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

  /// Pulls one pixel at a time until the trigger click, returning every haptic
  /// heard on the way. The finger then rests exactly on the trigger point.
  Future<List<String>> pullToTrigger(
    WidgetTester tester,
    TestGesture gesture,
  ) async {
    final heard = <String>[];
    for (var i = 0; i < 700 && !heard.contains('thresholdOn'); i++) {
      await gesture.moveBy(const Offset(0, 1));
      await tester.pump(const Duration(milliseconds: 16));
      heard.addAll(await spy.take(tester));
    }
    expect(heard, contains('thresholdOn'));
    return heard;
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

  testWidgets('hovering on the trigger point clicks off once and never '
      're-arms until backed off', (tester) async {
    await pumpList(tester);
    final gesture = await startPull(tester);
    await pullToTrigger(tester, gesture);
    final heard = <String>[];
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, i.isEven ? -2 : 2));
      await tester.pump(const Duration(milliseconds: 16));
      heard.addAll(await spy.take(tester));
    }
    // Below the trigger, letting go would not refresh, so it says so at once;
    // wobbling back over the line is not a new pull.
    expect(heard, ['thresholdOff']);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('pull to the trigger, back off 12 px and let go: told, and no '
      'refresh', (tester) async {
    await pumpList(tester);
    final gesture = await startPull(tester);
    await pullToTrigger(tester, gesture);
    await gesture.moveBy(const Offset(0, -12));
    await tester.pump(const Duration(milliseconds: 16));
    expect(await spy.take(tester), ['thresholdOff']);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshes, 0);
    expect(await spy.take(tester), isEmpty);
  });

  testWidgets('the trigger clicks again after backing off and crossing again', (
    tester,
  ) async {
    await pumpList(tester);
    final gesture = await startPull(tester);
    await pullToTrigger(tester, gesture);
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump(const Duration(milliseconds: 16));
    spy.kinds.clear();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 16));
    expect(await spy.take(tester), contains('thresholdOn'));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshes, 1);
  });

  testWidgets('a re-pull right after a refresh finishes is silent', (
    tester,
  ) async {
    await pumpList(tester);
    final done = Completer<void>();
    var called = 0;
    onRefresh = () {
      called++;
      return done.future;
    };
    final first = await startPull(tester);
    await pullToTrigger(tester, first);
    await first.moveBy(const Offset(0, 10));
    await first.up();
    // The indicator snaps to its spinner before it calls onRefresh.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(called, 1, reason: 'onRefresh is waiting on the completer');
    done.complete();
    await tester.pump(const Duration(milliseconds: 16));
    expect(await spy.take(tester), ['confirm']);

    // The indicator is still finishing its done animation and ignores this
    // pull, so it must not tick either.
    final second = await startPull(tester);
    await pullTo(tester, second, 0, 190);
    expect(await spy.take(tester), isEmpty);
    await second.up();
    await tester.pumpAndSettle();
    expect(refreshes, 0);

    // Once it has settled, pulls feel again.
    final third = await startPull(tester);
    await pullTo(tester, third, 0, 190);
    expect(await spy.take(tester), contains('thresholdOn'));
    await third.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the spring-back after letting go emits nothing', (tester) async {
    await pumpList(
      tester,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
    );
    final gesture = await startPull(tester);
    await pullToTrigger(tester, gesture);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    // The list bounces back from its overscroll, which is not a pull back.
    expect(await spy.take(tester), ['confirm']);
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

  testWidgets('Lists & Menus off silences pulling to refresh', (tester) async {
    await pumpList(tester);
    NavisHaptics.prefs = HapticsPrefs.fromColumns(
      true,
      HapticCategory.listsAndMenus.bit,
    );
    final gesture = await startPull(tester);
    await pullTo(tester, gesture, 0, 190);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    expect(await spy.take(tester), isEmpty);
  });
}
