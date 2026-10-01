import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';

void main() {
  test('ticks report the strongest ruler line crossed', () {
    expect(rulerTickFeedback(1.004, 1.006, 1), RulerTick.none);
    expect(rulerTickFeedback(1.01, 1.018, 1), RulerTick.none);
    expect(rulerTickFeedback(1.004, 1.012, 1), RulerTick.minor);
    expect(rulerTickFeedback(1.018, 1.02, 1), RulerTick.minor);
    expect(rulerTickFeedback(1.022, 1.018, 1), RulerTick.minor);
    expect(rulerTickFeedback(1.02, 1.018, 1), RulerTick.none);
    expect(rulerTickFeedback(1.095, 1.105, 1), RulerTick.major);
    expect(rulerTickFeedback(1.105, 1.095, 1), RulerTick.major);
    expect(rulerTickFeedback(0.995, 1.005, 1), RulerTick.neutral);
    expect(rulerTickFeedback(1.05, 0.95, 1), RulerTick.neutral);
    expect(rulerTickFeedback(-0.105, -0.095, 0), RulerTick.major);
    expect(rulerTickFeedback(0.004, -0.004, 0), RulerTick.neutral);
    expect(rulerTickFeedback(1, 1, 1), RulerTick.none);
  });

  Future<List<Object?>> scriptedDrag(
    WidgetTester tester, {
    required Duration step,
  }) async {
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    var value = 0.965;
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
    var time = Duration.zero;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(AdjustmentRuler)),
    );
    // Get past the drag slop, then clear the haptic log so only the
    // scripted 8 px (0.01) steps are measured.
    await gesture.moveBy(const Offset(-30, 0), timeStamp: time);
    await tester.pump();
    haptics.clear();
    for (var i = 0; i < 6; i++) {
      time += step;
      await gesture.moveBy(const Offset(-8, 0), timeStamp: time);
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    return haptics;
  }

  testWidgets('every line crossed while dragging produces a tick', (
    tester,
  ) async {
    final haptics = await scriptedDrag(
      tester,
      step: const Duration(milliseconds: 16),
    );
    // Six 0.01 steps from just below 1.00: five minor lines and exactly one
    // firmer tap where the drag passes 1.00.
    expect(
      haptics.where((h) => h == 'HapticFeedbackType.selectionClick'),
      hasLength(5),
    );
    expect(
      haptics.where((h) => h == 'HapticFeedbackType.mediumImpact'),
      hasLength(1),
    );
  });

  testWidgets('fast swipes throttle minor ticks but keep the neutral tap', (
    tester,
  ) async {
    final haptics = await scriptedDrag(
      tester,
      step: const Duration(milliseconds: 2),
    );
    expect(
      haptics.where((h) => h == 'HapticFeedbackType.selectionClick').length,
      lessThan(5),
    );
    expect(
      haptics.where((h) => h == 'HapticFeedbackType.mediumImpact'),
      hasLength(1),
    );
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

  testWidgets('a read-only ruler ignores drags', (tester) async {
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdjustmentRuler(
            value: 1,
            label: 'Pitch',
            valueLabel: '1.00',
            enabled: false,
            readOnly: true,
            onChanged: (_) => changes++,
            onChangeEnd: () {},
          ),
        ),
      ),
    );
    await tester.drag(find.byType(AdjustmentRuler), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(changes, 0);
  });

  group('external value changes glide like a swipe', () {
    Future<(List<Object?>, double Function(), void Function(double))> pumpRuler(
      WidgetTester tester, {
      bool reduceMotion = false,
    }) async {
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      var value = 1.0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return AdjustmentRuler(
                    value: value,
                    label: 'Speed',
                    valueLabel: value.toStringAsFixed(2),
                    resetValue: 1,
                    onChanged: (next) => setState(() => value = next),
                    onChangeEnd: () {},
                  );
                },
              ),
            ),
          ),
        ),
      );
      double visualValue() {
        final paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(AdjustmentRuler),
            matching: find.byType(CustomPaint),
          ),
        );
        return (paint.painter! as dynamic).value as double;
      }

      return (haptics, visualValue, (double v) => update(() => value = v));
    }

    testWidgets('a chip jump sweeps across the scale and ticks', (
      tester,
    ) async {
      final (haptics, visualValue, setValue) = await pumpRuler(tester);
      setValue(1.5);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      expect(visualValue(), greaterThan(1));
      expect(visualValue(), lessThan(1.5));
      // Real frames arrive about every 16 ms; each reports the lines it
      // crossed, just like successive drag updates.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(visualValue(), 1.5);
      expect(haptics, contains('HapticFeedbackType.lightImpact'));
      expect(haptics, contains('HapticFeedbackType.selectionClick'));
    });

    testWidgets('every later jump ticks too, not only the first', (
      tester,
    ) async {
      final (haptics, visualValue, setValue) = await pumpRuler(tester);
      for (final target in <double>[1.5, 0.75, 1.25, 1]) {
        haptics.clear();
        setValue(target);
        await tester.pump();
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pumpAndSettle();
        expect(visualValue(), target);
        expect(haptics, isNotEmpty, reason: 'jump to $target was silent');
      }
    });

    testWidgets('reduced motion jumps without haptics', (tester) async {
      final (haptics, visualValue, setValue) = await pumpRuler(
        tester,
        reduceMotion: true,
      );
      setValue(1.5);
      await tester.pump();
      expect(visualValue(), 1.5);
      expect(haptics, isEmpty);
    });
  });
}
