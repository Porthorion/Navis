import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';
import 'package:navis/src/features/settings/presentation/haptics_settings_screen.dart';

import '../../../../helpers/haptics_spy.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _Harness {
  const _Harness(this.tester, this.database);

  final WidgetTester tester;
  final NavisDatabase database;

  Future<AppSettingsTableData> row() async =>
      (await tester.runAsync(database.appSettingsDao.getSettings))!;

  SwitchListTile tile(String key) =>
      tester.widget<SwitchListTile>(find.byKey(ValueKey<String>(key)));

  Future<void> tap(String key) async {
    await tester.tap(find.byKey(ValueKey<String>(key)));
    await settle();
  }

  Future<void> settle() async {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Future<void> Function(AppSettingsDao dao)? seed,
}) async {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final database = createTestDatabase();
  await tester.runAsync(() async {
    await database.appSettingsDao.getSettings();
    await seed?.call(database.appSettingsDao);
  });
  final container = ProviderContainer(overrides: withTestDatabase(database));
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const HapticsSettingsScreen(),
      ),
    ),
  );
  final harness = _Harness(tester, database);
  await harness.settle();
  return harness;
}

void main() {
  testWidgets('shows the master and the six categories', (tester) async {
    final h = await _pump(tester);
    for (final title in [
      'Haptics',
      'Player Gestures',
      'Playback Buttons',
      'Sliders & Rulers',
      'Switches & Steppers',
      'Lists & Menus',
      'Likes & Alerts',
    ]) {
      expect(find.text(title), findsWidgets, reason: title);
    }
    expect(h.tile('haptics-master').value, isTrue);
    for (final category in HapticCategory.values) {
      expect(h.tile('haptics-${category.name}').value, isTrue);
      expect(h.tile('haptics-${category.name}').onChanged, isNotNull);
    }
  });

  testWidgets('master off disables every category and keeps their values', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      seed: (dao) async {
        await dao.setHapticCategoryEnabled(
          HapticCategory.listsAndMenus,
          enabled: false,
        );
        await dao.setHapticsEnabled(enabled: false);
      },
    );
    expect(h.tile('haptics-master').value, isFalse);
    for (final category in HapticCategory.values) {
      final tile = h.tile('haptics-${category.name}');
      expect(tile.onChanged, isNull, reason: category.name);
      expect(
        tile.value,
        category != HapticCategory.listsAndMenus,
        reason: category.name,
      );
    }
  });

  testWidgets('tapping a category and the master writes through', (
    tester,
  ) async {
    final h = await _pump(tester);
    await h.tap('haptics-playbackButtons');
    var row = await h.row();
    expect(row.hapticsDisabled, HapticCategory.playbackButtons.bit);
    expect(row.hapticsEnabled, isTrue);
    expect(h.tile('haptics-playbackButtons').value, isFalse);

    await h.tap('haptics-master');
    row = await h.row();
    expect(row.hapticsEnabled, isFalse);
    expect(row.hapticsDisabled, HapticCategory.playbackButtons.bit);
    expect(h.tile('haptics-playbackButtons').onChanged, isNull);

    await h.tap('haptics-master');
    expect((await h.row()).hapticsEnabled, isTrue);
    expect(h.tile('haptics-playbackButtons').value, isFalse);
  });

  testWidgets('the master clicks in both directions, even when prefs are off', (
    tester,
  ) async {
    final spy = HapticsSpy.install(tester);
    final h = await _pump(tester);
    await h.tap('haptics-master');
    expect(await spy.take(tester), ['toggleOff']);

    NavisHaptics.prefs = const HapticsPrefs(enabled: false);
    await h.tap('haptics-master');
    expect(await spy.take(tester), ['toggleOn']);
  });

  testWidgets('a category tile gives no click when its category is off', (
    tester,
  ) async {
    final spy = HapticsSpy.install(tester);
    final h = await _pump(tester);
    await h.tap('haptics-likesAndAlerts');
    expect(await spy.take(tester), ['toggleOff']);

    NavisHaptics.prefs = HapticsPrefs.fromColumns(
      true,
      HapticCategory.switchesAndSteppers.bit,
    );
    await h.tap('haptics-likesAndAlerts');
    expect(await spy.take(tester), isEmpty);
  });

  testWidgets('a locked category tile is silent', (tester) async {
    final spy = HapticsSpy.install(tester);
    final h = await _pump(
      tester,
      seed: (dao) => dao.setHapticsEnabled(enabled: false),
    );
    NavisHaptics.prefs = const HapticsPrefs(enabled: false);
    await h.tap('haptics-playerGestures');
    expect(await spy.take(tester), isEmpty);
    expect((await h.row()).hapticsDisabled, 0);
  });
}
