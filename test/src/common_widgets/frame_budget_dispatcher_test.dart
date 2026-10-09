import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/frame_budget_dispatcher.dart';

void main() {
  testWidgets('a throwing callback leaves the remaining queue runnable', (
    tester,
  ) async {
    final dispatcher = FrameBudgetDispatcher(perFrame: 2);
    final ran = <int>[];
    dispatcher.enqueue(() => throw StateError('failed update'));
    dispatcher.enqueue(() => ran.add(1));
    dispatcher.enqueue(() => ran.add(2));
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());
    expect(dispatcher.pending, 2);
    await tester.pump();
    expect(ran, [1, 2]);
    expect(dispatcher.pending, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('applies at most perFrame callbacks per frame, in order', (
    tester,
  ) async {
    final dispatcher = FrameBudgetDispatcher();
    final ran = <int>[];
    for (var i = 0; i < 8; i++) {
      dispatcher.enqueue(() => ran.add(i));
    }
    expect(ran, isEmpty);
    await tester.pump();
    expect(ran, <int>[0, 1, 2]);
    await tester.pump();
    expect(ran.length, 6);
    await tester.pump();
    expect(ran, <int>[0, 1, 2, 3, 4, 5, 6, 7]);
    expect(dispatcher.pending, 0);
    // Idle: nothing is scheduled any more.
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
