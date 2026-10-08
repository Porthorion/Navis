import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/frame_budget_dispatcher.dart';

void main() {
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
