import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/home/presentation/recommendation_auto_advance.dart';

void main() {
  testWidgets('one-shot deadlines require eligibility and cancel immediately', (
    tester,
  ) async {
    var advances = 0;
    final controller = RecommendationAutoAdvance(
      onAdvance: () => advances++,
      now: tester.binding.clock.now,
    );
    addTearDown(controller.dispose);
    await tester.pump(const Duration(seconds: 20));
    expect(advances, 0);
    controller.setEligible(eligible: true);
    await tester.pump(const Duration(seconds: 7));
    expect(advances, 0);
    // Repeated layout/status checks retain the original deadline.
    controller.setEligible(eligible: true);
    await tester.pump(const Duration(seconds: 1));
    expect(advances, 1);
    controller.setEligible(eligible: false);
    await tester.pump(const Duration(seconds: 30));
    expect(advances, 1);
    controller.setEligible(eligible: true);
    await tester.pump(const Duration(seconds: 7));
    expect(advances, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(advances, 2);
    controller.dispose();
  });

  testWidgets(
    'last interaction gets ten seconds even across a visibility interruption',
    (tester) async {
      var advances = 0;
      final controller = RecommendationAutoAdvance(
        onAdvance: () => advances++,
        now: tester.binding.clock.now,
      );
      addTearDown(controller.dispose);
      controller.setEligible(eligible: true);
      await tester.pump(const Duration(seconds: 6));
      controller.recordInteraction();
      await tester.pump(const Duration(seconds: 1));
      controller.recordInteraction();
      controller.setEligible(eligible: false);
      await tester.pump(const Duration(seconds: 1));
      controller.setEligible(eligible: true);
      await tester.pump(const Duration(seconds: 8));
      expect(advances, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(advances, 1);
      controller.dispose();
      await tester.pump(const Duration(seconds: 30));
      expect(advances, 1);
    },
  );
}
