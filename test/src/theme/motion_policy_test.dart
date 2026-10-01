import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/motion_policy.dart';

void main() {
  testWidgets('uses standard semantic timings by default', (tester) async {
    late MotionPolicy policy;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            policy = MotionPolicy.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(policy.reduceMotion, isFalse);
    expect(policy.navigationForward, const Duration(milliseconds: 280));
    expect(policy.navigationReverse, const Duration(milliseconds: 220));
    expect(policy.feedback, const Duration(milliseconds: 120));
    expect(policy.surface, const Duration(milliseconds: 180));
  });

  testWidgets('removes nonessential motion when the platform requests it', (
    tester,
  ) async {
    late MotionPolicy policy;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              policy = MotionPolicy.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(policy.reduceMotion, isTrue);
    expect(policy.navigationForward, Duration.zero);
    expect(policy.navigationReverse, Duration.zero);
    expect(policy.feedback, Duration.zero);
    expect(policy.surface, Duration.zero);
  });
}
