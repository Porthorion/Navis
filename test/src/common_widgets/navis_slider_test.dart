import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/navis_slider.dart';
import 'package:navis/src/features/player/presentation/desktop_volume_slider.dart';

import '../../helpers/semantics_update_recorder.dart';

/// Pushes [page] as a route above a plain home screen: the case where
/// material's `Slider` overlay portal sends the engine an orphan semantics node.
Future<void> _pumpPushed(WidgetTester tester, Widget page) async {
  SemanticsUpdateRecorderBinding.clear();
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('home')),
    ),
  );
  navigator.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: Center(child: page)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  SemanticsUpdateRecorderBinding();

  group('orphan semantics nodes in a pushed route', () {
    late SemanticsHandle semantics;
    setUp(() => semantics = SemanticsBinding.instance.ensureSemantics());
    tearDown(() => semantics.dispose());

    testWidgets('DesktopVolumeSlider sends none', (tester) async {
      await _pumpPushed(
        tester,
        SizedBox(
          width: 300,
          child: DesktopVolumeSlider(
            volume: 0.4,
            semanticLabel: 'Volume',
            muteTooltip: 'Mute',
            unmuteTooltip: 'Unmute',
            onChanged: (_) {},
            onChangeEnd: (_) {},
            onMuteToggle: () {},
          ),
        ),
      );
      expect(SemanticsUpdateRecorderBinding.orphans, isEmpty);
    });

    for (final enabled in <bool>[true, false]) {
      testWidgets('NavisSlider sends none (enabled: $enabled)', (tester) async {
        await _pumpPushed(
          tester,
          SizedBox(
            width: 300,
            child: NavisSlider(value: 0.3, onChanged: enabled ? (_) {} : null),
          ),
        );
        expect(SemanticsUpdateRecorderBinding.orphans, isEmpty);
      });
    }

    testWidgets('a bare Slider still sends one (guards the premise)', (
      tester,
    ) async {
      await _pumpPushed(
        tester,
        SizedBox(width: 300, child: Slider(value: 0.3, onChanged: (_) {})),
      );
      expect(SemanticsUpdateRecorderBinding.orphans, isNotEmpty);
    });
  });

  group('NavisSlider behaves like Slider', () {
    testWidgets('keeps the Slider size, gestures, key and semantics', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      double? changed;
      double? ended;
      Future<Size> sizeOf(Widget slider) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[SizedBox(width: 300, child: slider)],
              ),
            ),
          ),
        );
        return tester.getSize(find.byType(Slider));
      }

      final bare = await sizeOf(Slider(value: 0.5, onChanged: (_) {}));
      final wrapped = await sizeOf(
        NavisSlider(
          sliderKey: const ValueKey<String>('s'),
          value: 0.5,
          semanticFormatterCallback: (v) => '${(v * 100).round()}%',
          onChanged: (v) => changed = v,
          onChangeEnd: (v) => ended = v,
        ),
      );
      expect(wrapped, bare);
      expect(
        tester.getSize(find.byType(NavisSlider)),
        tester.getSize(find.byType(Slider)),
      );
      // The key lands on the inner Slider so `find.byKey` still sees a Slider.
      expect(
        tester.widget(find.byKey(const ValueKey<String>('s'))),
        isA<Slider>(),
      );
      expect(find.semantics.byValue('50%'), findsOneWidget);
      expect(find.semantics.byAction(SemanticsAction.increase), findsOneWidget);

      await tester.dragFrom(
        tester.getCenter(find.byType(Slider)),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();
      expect(changed, greaterThan(0.5));
      expect(ended, greaterThan(0.5));
      handle.dispose();
    });

    testWidgets('draws the value indicator in its own unclipped overlay', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: NavisSlider(
                  value: 3,
                  min: 1,
                  max: 12,
                  divisions: 11,
                  label: '3 seconds',
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Slider)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      // The value indicator is an OverlayPortal child of the slider, so it
      // paints in the slider's own overlay, and that overlay does not clip it.
      final overlay = find.descendant(
        of: find.byType(NavisSlider),
        matching: find.byType(Overlay),
      );
      expect(
        Overlay.of(tester.element(find.byType(Slider))),
        tester.state<OverlayState>(overlay),
      );
      expect(tester.widget<Overlay>(overlay).clipBehavior, Clip.none);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}
