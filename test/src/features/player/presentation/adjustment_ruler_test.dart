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

  testWidgets('the scale sits flat and outlines itself only for the keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdjustmentRuler(
            value: 1,
            label: 'Speed',
            valueLabel: '1.00',
            resetValue: 1,
            onChanged: (_) {},
            onChangeEnd: () {},
          ),
        ),
      ),
    );
    BoxDecoration decoration() =>
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: find.byType(AdjustmentRuler),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(decoration().gradient, isNull);
    expect(decoration().color, isNull);
    expect(decoration().border, isNull);

    // Touch input focuses the ruler without outlining it, tap or drag.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    await tester.tap(find.byType(AdjustmentRuler));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(decoration().border, isNull);
    await tester.drag(find.byType(AdjustmentRuler), const Offset(-40, 0));
    await tester.pump();
    expect(decoration().border, isNull);

    // Keyboard focus draws it, and it goes again when touch takes over.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await tester.pump();
    expect(decoration().border, isNotNull);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    await tester.pump();
    expect(decoration().border, isNull);
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

  group('whole-step mode', () {
    test('every step is a minor tick and zero is the neutral one', () {
      RulerTick step(double from, double to) =>
          rulerTickFeedback(from, to, 0, perUnit: 1, majorEvery: null);
      expect(step(1.2, 1.8), RulerTick.none);
      expect(step(1.2, 2.1), RulerTick.minor);
      expect(step(2.1, 0.9), RulerTick.minor);
      expect(step(-0.4, 0.4), RulerTick.neutral);
      expect(step(0.4, -0.4), RulerTick.neutral);
      expect(step(-3.2, 4.6), RulerTick.neutral);
      expect(step(2, 2), RulerTick.none);
    });

    testWidgets('drag settles on steps with a tick each and a firmer zero', (
      tester,
    ) async {
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
      var value = -2.0;
      final sent = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => AdjustmentRuler(
                value: value,
                label: 'Color',
                valueLabel: '$value',
                range: const AdjustmentRange(minimum: -5, maximum: 5),
                snapStep: 1,
                pixelsPerUnit: 32,
                labelBuilder: (v) => '${v.round()}',
                onChanged: (next) {
                  sent.add(next);
                  setState(() => value = next);
                },
                onChangeEnd: () {},
              ),
            ),
          ),
        ),
      );
      final drag = await tester.startGesture(
        tester.getCenter(find.byType(AdjustmentRuler)),
      );
      await drag.moveBy(const Offset(-30, 0), timeStamp: Duration.zero);
      await tester.pump();
      haptics.clear();
      var time = Duration.zero;
      for (var i = 0; i < 5; i++) {
        time += const Duration(milliseconds: 40);
        await drag.moveBy(const Offset(-16, 0), timeStamp: time);
        await tester.pump();
      }
      await drag.up();
      await tester.pumpAndSettle();

      expect(
        sent,
        everyElement(predicate<double>((v) => v == v.roundToDouble())),
      );
      expect(value, greaterThan(-2));
      expect(
        haptics.where((h) => h == 'HapticFeedbackType.mediumImpact'),
        hasLength(1),
        reason: 'zero is crossed once',
      );
      expect(
        haptics.where((h) => h == 'HapticFeedbackType.lightImpact'),
        hasLength(2),
        reason: 'the rounded step changes to -1 and to 1 as well as to 0',
      );
    });

    test('snap ticks click on lines and tap when the rounded step changes', () {
      RulerTick tick(double from, double to) =>
          snapTickFeedback(from, to, 0, perUnit: 1, subdivisions: 8);
      expect(tick(0.02, 0.1), RulerTick.none);
      expect(tick(0.1, 0.14), RulerTick.minor, reason: 'line at 0.125');
      expect(tick(0.9, 1.1), RulerTick.minor, reason: 'line at the step');
      expect(tick(0.4, 0.6), RulerTick.major, reason: '0 rounds to 1 at 0.5');
      expect(tick(0.6, 0.4), RulerTick.neutral, reason: 'it becomes 0');
      expect(tick(-0.4, -0.6), RulerTick.major, reason: 'leaving 0 is light');
      expect(tick(2.6, 1.4), RulerTick.major);
      expect(tick(-1.4, 0.6), RulerTick.major, reason: 'lands on step 1');
      expect(tick(-1.6, 0.4), RulerTick.neutral, reason: 'lands on step 0');
      expect(
        tick(0.4, -0.4),
        RulerTick.minor,
        reason: 'crossing the zero line is not a change of step',
      );
      expect(tick(1.7, 1.7), RulerTick.none);
    });

    group('haptics while dragging at 64 px a step', () {
      Future<List<Object?>> drag(
        WidgetTester tester, {
        required double from,
        required double delta,
        Duration interval = const Duration(milliseconds: 40),
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
        var value = from;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => AdjustmentRuler(
                  value: value,
                  label: 'Color',
                  valueLabel: '$value',
                  range: const AdjustmentRange(minimum: -5, maximum: 5),
                  snapStep: 1,
                  pixelsPerUnit: 64,
                  labelBuilder: (v) => '${v.round()}',
                  onChanged: (next) => setState(() => value = next),
                  onChangeEnd: () {},
                ),
              ),
            ),
          ),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(AdjustmentRuler)),
        );
        // Get past the drag slop, which starts the drag without moving it.
        await gesture.moveBy(const Offset(-30, 0), timeStamp: Duration.zero);
        await tester.pump();
        haptics.clear();
        var time = Duration.zero;
        // 5 px is less than the 8 px between lines, so each move crosses at
        // most one.
        for (var i = 0; i < delta.abs() * 64 / 5; i++) {
          time += interval;
          await gesture.moveBy(Offset(-5 * delta.sign, 0), timeStamp: time);
          await tester.pump();
        }
        await gesture.up();
        await tester.pumpAndSettle();
        return haptics;
      }

      int count(List<Object?> haptics, String type) =>
          haptics.where((h) => h == 'HapticFeedbackType.$type').length;

      testWidgets('click on each line and tap when the step changes', (
        tester,
      ) async {
        // -2 to just short of 2: 31 lines, of which the four at the half
        // steps -1.5, -0.5, 0.5 and 1.5 are where the rounded step changes.
        final haptics = await drag(tester, from: -2, delta: 3.984375);
        expect(count(haptics, 'selectionClick'), 27);
        expect(count(haptics, 'lightImpact'), 3);
        expect(count(haptics, 'mediumImpact'), 1, reason: 'only to zero');
      });

      testWidgets('dragging down across zero taps once, on reaching it', (
        tester,
      ) async {
        final haptics = await drag(tester, from: 2, delta: -3.984375);
        expect(count(haptics, 'selectionClick'), 27);
        expect(count(haptics, 'lightImpact'), 3);
        expect(count(haptics, 'mediumImpact'), 1);
      });

      testWidgets('a nudge inside one step is silent', (tester) async {
        final haptics = await drag(tester, from: 1, delta: 0.0390625);
        expect(haptics, isEmpty);
      });

      testWidgets('fast swipes throttle the clicks but not the taps', (
        tester,
      ) async {
        final haptics = await drag(
          tester,
          from: -2,
          delta: 3.984375,
          interval: const Duration(milliseconds: 2),
        );
        expect(count(haptics, 'selectionClick'), lessThan(10));
        expect(count(haptics, 'lightImpact'), 3);
        expect(count(haptics, 'mediumImpact'), 1);
      });
    });

    testWidgets('keyboard moves a step and the next value is announced', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var value = 1.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => AdjustmentRuler(
                value: value,
                label: 'Color',
                valueLabel: '$value',
                range: const AdjustmentRange(minimum: -5, maximum: 5),
                snapStep: 1,
                pixelsPerUnit: 32,
                labelBuilder: (v) => 'step ${v.round()}',
                onChanged: (next) => setState(() => value = next),
                onChangeEnd: () {},
              ),
            ),
          ),
        ),
      );
      final data = tester
          .getSemantics(find.byType(AdjustmentRuler))
          .getSemanticsData();
      expect(data.increasedValue, 'step 2');
      expect(data.decreasedValue, 'step 0');
      await tester.tap(find.byType(AdjustmentRuler));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(value, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(value, 0);
      handle.dispose();
    });
  });
}
