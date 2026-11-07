import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/navis_switch.dart';

import '../../helpers/haptics_spy.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget body) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));

  testWidgets('a settings switch tile feels on then off', (tester) async {
    final spy = HapticsSpy.install(tester);
    var value = false;
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => NavisSwitchListTile(
          title: const Text('Gapless'),
          value: value,
          onChanged: (next) => setState(() => value = next),
        ),
      ),
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(value, isFalse);
    expect(await spy.take(tester), ['toggleOn', 'toggleOff']);
  });

  testWidgets('a bare switch and the adaptive variants feel like switches', (
    tester,
  ) async {
    final spy = HapticsSpy.install(tester);
    var calls = 0;
    await pump(
      tester,
      Column(
        children: [
          NavisSwitch(value: false, onChanged: (_) => calls++),
          NavisSwitch.adaptive(value: true, onChanged: (_) => calls++),
          NavisSwitchListTile.adaptive(
            title: const Text('Tile'),
            value: false,
            onChanged: (_) => calls++,
          ),
        ],
      ),
    );
    await tester.tap(find.byType(Switch).first);
    await tester.tap(find.byType(Switch).at(1));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(calls, 3);
    expect(await spy.take(tester), ['toggleOn', 'toggleOff', 'toggleOn']);
  });

  testWidgets('a disabled switch stays disabled and silent', (tester) async {
    final spy = HapticsSpy.install(tester);
    await pump(
      tester,
      Column(
        children: [
          NavisSwitchListTile(
            title: const Text('Off'),
            value: false,
            onChanged: null,
          ),
        ],
      ),
    );
    await tester.tap(find.byType(SwitchListTile), warnIfMissed: false);
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    expect(await spy.take(tester), isEmpty);
  });
}
