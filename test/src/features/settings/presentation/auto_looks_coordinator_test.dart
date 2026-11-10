import 'dart:ui' show Brightness;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/features/settings/presentation/appearance_preset_controller.dart';
import 'package:navis/src/features/settings/presentation/auto_looks_coordinator.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_color_style.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  late ProviderContainer container;
  late String lightId;
  late String darkId;
  var clock = DateTime(2026, 11, 10, 12);

  late AppSettingsDao dao;
  Future<AppSettingsModel> settings() =>
      container.read(settingsRepositoryProvider).getSettings();
  Future<void> idle() async {
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Saves a Light and a Dark Look that each carry Auto-owned fields (theme
  /// mode, OLED, a disabled night schedule), then moves the top-level
  /// settings somewhere else so a leak of those fields would show.
  Future<void> prepare({
    bool enabled = true,
    String? applied,
    String source = 'device',
    List<Override> extra = const [],
  }) async {
    database = createTestDatabase();
    dao = database.appSettingsDao;
    clock = DateTime(2026, 11, 10, 12);
    container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [nowProvider.overrideWithValue(() => clock), ...extra],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    container.listen(appSettingsProvider, (_, _) {});
    await container.read(appSettingsProvider.future);
    await dao.updateThemeMode('oled');
    await dao.updateOledForAuto(enabled: true);
    await dao.updateNightSchedule(
      enabled: false,
      startMinutes: 600,
      endMinutes: 660,
    );
    final looks = container.read(appearanceLooksControllerProvider.notifier);
    await dao.updateColorStyle('pastel');
    lightId = (await looks.saveAsNew('Light look')).value!.id;
    await dao.updateColorStyle('immersive');
    darkId = (await looks.saveAsNew('Dark look')).value!.id;
    await dao.updateColorStyle('neutral');
    await dao.updateThemeMode('system');
    await dao.updateOledForAuto(enabled: false);
    await dao.updateNightSchedule(
      enabled: true,
      startMinutes: 1320,
      endMinutes: 420,
    );
    await dao.updateAutoTheme(source: source);
    await dao.updateAutoLooks(
      enabled: enabled,
      lightLookId: lightId,
      darkLookId: darkId,
    );
    if (applied != null) await dao.updateAutoLooksAppliedMode(applied);
    await idle();
  }

  void start() => container.listen(autoLooksCoordinatorProvider, (_, _) {});
  Future<void> flip({required bool dark}) async {
    container
        .read(platformBrightnessProvider.notifier)
        .set(dark ? Brightness.dark : Brightness.light);
    await idle();
  }

  Future<void> expectAutoFieldsUntouched() async {
    final s = await settings();
    expect(s.themeMode, 'system');
    expect(s.oledForAuto, isFalse);
    expect(s.nightScheduleEnabled, isTrue);
    expect(s.nightScheduleStartMinutes, 1320);
    expect(s.nightScheduleEndMinutes, 420);
  }

  group('AutoLooksCoordinator', () {
    test(
      'applies the mode Look at start, minus the Auto-owned fields',
      () async {
        await prepare();
        start();
        await idle();
        final s = await settings();
        expect(s.colorStyle, 'pastel');
        expect(s.autoLooksAppliedMode, 'light');
        expect(s.selectedAppearanceLookId, lightId);
        await expectAutoFieldsUntouched();
      },
      skip: !sqliteAvailable,
    );

    test('a switch applies the other Look once; a restart in the same mode '
        'does not re-apply', () async {
      await prepare(applied: 'light');
      start();
      await idle();
      expect((await settings()).colorStyle, 'neutral', reason: 'same mode');
      await flip(dark: true);
      var s = await settings();
      expect(s.colorStyle, 'immersive');
      expect(s.autoLooksAppliedMode, 'dark');
      await expectAutoFieldsUntouched();
      // A tweak survives until the next switch, and shows as Custom.
      await dao.updateColorStyle('neutral');
      await idle();
      expect((await settings()).colorStyle, 'neutral');
      expect(
        container.read(appearanceLooksControllerProvider).selectedLookId,
        isNull,
      );
      await flip(dark: false);
      s = await settings();
      expect(s.colorStyle, 'pastel', reason: 'the preset wins after a switch');
      expect(s.autoLooksAppliedMode, 'light');
    }, skip: !sqliteAvailable);

    test(
      'a Look is shown as selected, not Custom, while Auto presets are on',
      () async {
        await prepare();
        start();
        await idle();
        expect(
          container.read(appearanceLooksControllerProvider).selectedLookId,
          lightId,
        );
      },
      skip: !sqliteAvailable,
    );

    test('does nothing while off or while the mode is not Auto', () async {
      await prepare(enabled: false);
      start();
      await flip(dark: true);
      expect((await settings()).colorStyle, 'neutral');
      expect((await settings()).autoLooksAppliedMode, isNull);
      await dao.updateThemeMode('dark');
      await dao.updateAutoLooks(enabled: true);
      await idle();
      expect((await settings()).colorStyle, 'neutral');
    }, skip: !sqliteAvailable);

    test(
      'turning the switch on or changing the current mode Look applies it',
      () async {
        await prepare(enabled: false);
        start();
        await idle();
        expect((await settings()).colorStyle, 'neutral');
        await dao.updateAutoLooks(enabled: true);
        await idle();
        expect((await settings()).colorStyle, 'pastel');
        await dao.updateColorStyle('neutral');
        // The other mode's choice waits for its switch.
        await dao.updateAutoLooks(darkLookId: lightId);
        await idle();
        expect((await settings()).colorStyle, 'neutral');
        await dao.updateAutoLooks(lightLookId: darkId);
        await idle();
        expect((await settings()).colorStyle, 'immersive');
        expect((await settings()).autoLooksAppliedMode, 'light');
      },
      skip: !sqliteAvailable,
    );

    test(
      'None and a deleted Look apply nothing but still record the mode',
      () async {
        await prepare();
        start();
        await idle();
        await dao.updateAutoLooks(darkLookId: '');
        await flip(dark: true);
        var s = await settings();
        expect(s.colorStyle, 'pastel', reason: 'None keeps the current look');
        expect(s.autoLooksAppliedMode, 'dark');
        await dao.updateAutoLooks(darkLookId: darkId);
        await idle();
        expect((await settings()).colorStyle, 'immersive');
        await flip(dark: false);
        await dao.updateColorStyle('neutral');
        await container
            .read(appearanceLooksControllerProvider.notifier)
            .delete(darkId);
        await flip(dark: true);
        s = await settings();
        expect(
          s.colorStyle,
          'neutral',
          reason: 'a deleted Look applies nothing',
        );
        expect(s.autoLooksAppliedMode, 'dark');
        await expectAutoFieldsUntouched();
      },
      skip: !sqliteAvailable,
    );

    test(
      'a failed apply leaves the mode unrecorded so the next trigger retries',
      () async {
        await prepare(
          extra: [
            appearanceLooksControllerProvider.overrideWith(_FailingLooks.new),
          ],
        );
        start();
        await idle();
        final s = await settings();
        expect(s.autoLooksAppliedMode, isNull);
        expect(s.colorStyle, 'neutral');
      },
      skip: !sqliteAvailable,
    );

    test('an Auto apply leaves the manual apply Undo origin alone', () async {
      await prepare(enabled: false);
      final looks = container.read(appearanceLooksControllerProvider.notifier);
      final origin = (await settings()).selectedAppearanceLookId;
      expect(origin, isNot(lightId));
      final previous = await looks.apply(lightId);
      await looks.apply(darkId, only: autoLookSnapshot);
      expect(await looks.restore(previous!), isNull);
      expect((await settings()).selectedAppearanceLookId, origin);
    }, skip: !sqliteAvailable);

    test('follows the schedule source too', () async {
      await prepare(source: 'schedule');
      start();
      await idle();
      expect((await settings()).colorStyle, 'pastel');
      clock = DateTime(2026, 11, 10, 23);
      container.invalidate(effectiveDarkProvider);
      await idle();
      final s = await settings();
      expect(s.colorStyle, 'immersive');
      expect(s.autoLooksAppliedMode, 'dark');
      await expectAutoFieldsUntouched();
    }, skip: !sqliteAvailable);

    test('the Night schedule still overrides the Look color style', () async {
      await prepare();
      clock = DateTime(2026, 11, 10, 23);
      start();
      await idle();
      container.listen(effectiveColorStyleProvider, (_, _) {});
      expect(container.read(colorStyleProvider), NavisColorStyle.pastel);
      expect(
        container.read(effectiveColorStyleProvider),
        NavisColorStyle.night,
      );
    }, skip: !sqliteAvailable);
  });
}

class _FailingLooks extends AppearanceLooksController {
  @override
  Future<AppearanceSnapshot?> apply(
    String id, {
    AppearanceSnapshot Function(AppearanceSnapshot)? only,
  }) async => null;
}
