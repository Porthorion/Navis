import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/star_button.dart';

import '../../helpers/haptics_spy.dart';

import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';

void main() {
  for (final (starred, kind) in [(false, 'confirm'), (true, 'tick')]) {
    testWidgets('${starred ? 'unliking' : 'liking'} gives the $kind haptic', (
      tester,
    ) async {
      final spy = HapticsSpy.install(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StarButton(
              isStarred: starred,
              tooltip: 'Like',
              onPressed: () {},
              compact: true,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(await spy.take(tester), [kind]);
    });
  }

  testWidgets('Likes & Alerts off silences the like button', (tester) async {
    final spy = HapticsSpy.install(tester);
    NavisHaptics.prefs = HapticsPrefs.fromColumns(
      true,
      HapticCategory.likesAndAlerts.bit,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StarButton(
            isStarred: false,
            tooltip: 'Like',
            onPressed: () {},
            compact: true,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(await spy.take(tester), isEmpty);
  });
}
