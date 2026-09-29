import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';

void main() {
  test('detent is detected when a drag lands on or crosses neutral', () {
    expect(crossesDetent(0.98, 1.02, 1), isTrue);
    expect(crossesDetent(1.02, 0.98, 1), isTrue);
    expect(crossesDetent(0.98, 1, 1), isTrue);
    expect(crossesDetent(1, 1.02, 1), isFalse);
    expect(crossesDetent(1.02, 1.05, 1), isFalse);
    expect(crossesDetent(-0.5, 0.5, 0), isTrue);
  });

  testWidgets('dragging across the neutral value emits one selection click', (
    tester,
  ) async {
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate')
          haptics.add(call.arguments);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    var value = 0.95;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AdjustmentRuler(
              value: value,
              label: 'Speed',
              valueLabel: value.toStringAsFixed(2),
              resetValue: 1,
              onChanged: (next) => setState(() => value = next),
              onChangeEnd: () {},
            ),
          ),
        ),
      ),
    );
    // Moving the scale left raises the value: 0.95 → about 1.05.
    await tester.drag(find.byType(AdjustmentRuler), const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(value, greaterThan(1));
    expect(haptics, ['HapticFeedbackType.selectionClick']);
  });

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'fine drag snaps without extra audio updates, reduced motion $reducedMotion',
      (tester) async {
        var value = 1.0;
        final changes = <double>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(disableAnimations: reducedMotion),
                child: StatefulBuilder(
                  builder: (context, setState) => AdjustmentRuler(
                    value: value,
                    label: 'Speed',
                    valueLabel: value.toStringAsFixed(2),
                    onChanged: (next) {
                      changes.add(next);
                      setState(() => value = next);
                    },
                    onChangeEnd: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        final ruler = find.byType(AdjustmentRuler);
        final drag = await tester.startGesture(tester.getCenter(ruler));
        await drag.moveBy(const Offset(-24, 0));
        await tester.pump();
        await drag.moveBy(const Offset(-13, 0));
        await tester.pump();
        expect(value, greaterThan(1));
        expect(isHundredth(value), isTrue);
        await drag.up();
        await tester.pump();
        final count = changes.length;
        await tester.pumpAndSettle();
        expect(changes.length, count);
        expect(tester.binding.transientCallbackCount, 0);
      },
    );
  }
  testWidgets(
    'clamped drag reverses immediately and reset cancels the gesture',
    (tester) async {
      var value = 1.09;
      var token = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return AdjustmentRuler(
                  value: value,
                  label: 'Speed',
                  valueLabel: '$value',
                  interactionToken: token,
                  range: const AdjustmentRange(minimum: 0.1, maximum: 1.1),
                  onChanged: (next) => setState(() => value = next),
                  onChangeEnd: () {},
                );
              },
            ),
          ),
        ),
      );
      final drag = await tester.startGesture(
        tester.getCenter(find.byType(AdjustmentRuler)),
      );
      await drag.moveBy(const Offset(-24, 0));
      await tester.pump();
      await drag.moveBy(const Offset(-1000, 0));
      await tester.pump();
      expect(value, 1.1);
      await drag.moveBy(const Offset(8, 0));
      await tester.pump();
      expect(value, 1.09);
      update(() {
        value = 1;
        token++;
      });
      await tester.pump();
      await drag.moveBy(const Offset(-32, 0));
      await drag.up();
      await tester.pumpAndSettle();
      expect(value, 1);
    },
  );
}
