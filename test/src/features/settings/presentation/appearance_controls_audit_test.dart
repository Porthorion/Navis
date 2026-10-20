import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/domain/home_section_ids.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/domain/album_title_shade.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/night_schedule.dart';
import 'package:navis/src/features/settings/presentation/appearance_preset_controller.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/corner_style_provider.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

/// One control on the Appearance page, driven through the real screen.
///
/// [fields] are the Look fields the control changes (empty for settings a
/// Look does not hold) and [columns] the settings columns it writes. Both are
/// compared with what actually changed, so a control that writes a second
/// field, the wrong field or nothing fails its row. [writers] name the DAO
/// writes the control uses; the guard test below fails when the screen gains
/// a writer no row lists.
class _Control {
  const new(
    this.name, {
    required this.writers,
    required this.columns,
    required this.act,
    required this.effect,
    this.fields = const <String>{},
    this.seed,
    this.desktop = false,
  });

  final String name;
  final Set<String> writers;
  final Set<String> columns;
  final Set<String> fields;
  final bool desktop;

  /// Settings in place before the Look is saved, so the control has something
  /// to change.
  final Future<void> Function(NavisDatabase db)? seed;
  final Future<void> Function(WidgetTester tester) act;

  /// The app-level state the rest of the app reads.
  final void Function(ProviderContainer container) effect;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('en'));
  late NavisDatabase database;
  late ProviderContainer container;

  setUpAll(() async {
    final inter = FontLoader(navisFontFamily)
      ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([inter.load(), icons.load()]);
  });

  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  // ── harness ──────────────────────────────────────────────────────────────

  Widget app({required bool desktop}) {
    const screen = AppearanceSettingsScreen();
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // 24-hour so the time picker's input mode takes plain numbers.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
        theme: buildDarkTheme(
          resolveColorSchemeSeedColor(null),
          style: NavisColorStyle.pastel,
        ),
        home: desktop
            ? AdaptiveContextScope(
                adaptiveContext: resolveAdaptiveContext(
                  desktopRuntime: true,
                  viewportSize: const Size(1280, 7000),
                  safePadding: EdgeInsets.zero,
                ),
                child: screen,
              )
            : screen,
      ),
    );
  }

  /// Drift's re-query lives in the fake-async zone, so each real write gets a
  /// turn there. Bounded pumps: the page has an endlessly blinking icon, so
  /// it never settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await settle(tester);
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    required Future<void> Function(NavisDatabase db)? seed,
    required bool desktop,
  }) async {
    // Tall enough that every control is built without scrolling.
    setAdaptiveTestViewport(
      tester,
      desktop ? const Size(1280, 7000) : const Size(390, 7000),
    );
    database = createTestDatabase();
    await tester.runAsync(() async {
      await database.appSettingsDao.getSettings();
      await database.appSettingsDao.updateColorStyle('pastel');
      await database.appSettingsDao.updateThemeMode('dark');
      await seed?.call(database);
    });
    container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          pendingSetupHighlightsProvider.overrideWithValue(
            const <SetupHighlight>{},
          ),
          nowProvider.overrideWithValue(() => DateTime(2026, 10, 10, 23)),
          setupHighlightsServiceProvider.overrideWith(
            (ref) =>
                SetupHighlightsService(() async {}, () async {}, (_) async {}),
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    await tester.pumpWidget(app(desktop: desktop));
    await settle(tester);
  }

  /// Leaves the page and comes back to it with the same container.
  Future<void> reenter(WidgetTester tester, {required bool desktop}) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(desktop: desktop));
    await settle(tester);
  }

  Future<Map<String, Object?>> row(WidgetTester tester) async =>
      Map<String, Object?>.from(
        (await tester.runAsync(database.appSettingsDao.getSettings))!.toJson(),
      );

  Set<String> changed(
    Map<String, Object?> before,
    Map<String, Object?> after,
  ) => {
    for (final key in {...before.keys, ...after.keys})
      if (key != 'updatedAt' && before[key] != after[key]) key,
  };

  AppSettingsModel settings() =>
      container.read(appSettingsProvider).requireValue;
  Map<String, Object?> snapshot() =>
      AppearanceSnapshot.capture(settings()).toJson();
  AppearanceLooksState looks() =>
      container.read(appearanceLooksControllerProvider);

  final dropdown = find.byKey(const ValueKey<String>('appearanceLookDropdown'));
  String pickerText(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(of: dropdown, matching: find.byType(TextField)),
      )
      .controller!
      .text;

  Future<void> openLookMenu(WidgetTester tester) async {
    await tap(
      tester,
      find.byKey(const ValueKey<String>('appearanceLookActions')),
    );
  }

  Future<void> saveBaseLook(WidgetTester tester) async {
    var done = false;
    final saving = container
        .read(appearanceLooksControllerProvider.notifier)
        .saveAsNew('Base')
        .whenComplete(() => done = true);
    for (var i = 0; i < 20 && !done; i++) {
      await settle(tester);
    }
    await saving;
    await settle(tester);
  }

  // ── finders ──────────────────────────────────────────────────────────────

  Finder within(Key key, String text) =>
      find.descendant(of: find.byKey(key), matching: find.text(text));
  Finder inSelector(String key, String text) =>
      within(ValueKey<String>(key), text);
  Finder shape(String label, String option) => find.descendant(
    of: find
        .ancestor(of: find.text(label), matching: find.byType(Column))
        .first,
    matching: find.text(option),
  );
  Finder themeMode(String label) => find.descendant(
    of: find.byType(ThemeModeSelector),
    matching: find.text(label),
  );
  Finder headerOf(String title) => find.text(title);
  Finder panelKey(String name) =>
      find.byKey(ValueKey<String>('colorTuning-$name'));

  /// Opens Fine-Tune Colors, runs [steps], and closes the panel again.
  Future<void> withTuningPanel(
    WidgetTester tester,
    Future<void> Function() steps,
  ) async {
    await tap(tester, find.byKey(const ValueKey<String>('colorTuningOption')));
    await steps();
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(tester);
  }

  Future<void> expandGroup(WidgetTester tester, String title) async {
    await tap(tester, headerOf(title));
  }

  Future<void> pickHex(WidgetTester tester, String hex, String button) async {
    await tap(
      tester,
      find.descendant(
        of: find.byType(ColorSchemeGrid),
        matching: find.byIcon(Icons.add),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextField, l10n.appearanceColorPickerHexLabel),
      hex,
    );
    await settle(tester);
    await tap(tester, find.text(button));
  }

  Future<void> pickNightTime(
    WidgetTester tester, {
    required bool start,
    required int hour,
    required int minute,
  }) async {
    final chips = find.byType(ActionChip);
    await tap(tester, start ? chips.first : chips.last);
    await tap(tester, find.byIcon(Icons.keyboard_outlined));
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '$hour');
    await tester.enterText(fields.at(1), '$minute');
    await tap(tester, find.text('OK'));
  }

  int presetValue(int index) => presetColors[index].color.toARGB32();
  Future<void> nightOn(NavisDatabase db) =>
      db.appSettingsDao.updateNightSchedule(
        enabled: true,
        startMinutes: NightSchedule.defaultStartMinutes,
        endMinutes: NightSchedule.defaultEndMinutes,
      );
  const hiddenOnce = '["recently_added"]';

  // ── the table ────────────────────────────────────────────────────────────

  final controls = <_Control>[
    // Theme
    for (final (name, label, value) in <(String, String, String)>[
      ('light', l10n.appearanceThemeLight, 'light'),
      ('oled', l10n.appearanceThemeOled, 'oled'),
      ('system', l10n.appearanceThemeSystem, 'system'),
    ])
      _Control(
        'Theme mode: $name',
        writers: {'updateThemeMode'},
        columns: {'themeMode'},
        fields: {'themeMode'},
        act: (t) => tap(t, themeMode(label)),
        effect: (c) => expect(c.read(themeModeProvider), value),
      ),
    _Control(
      'Use OLED when dark (Auto)',
      writers: {'updateOledForAuto'},
      columns: {'oledForAuto'},
      fields: {'oledForAuto'},
      seed: (db) => db.appSettingsDao.updateThemeMode('system'),
      act: (t) => tap(t, find.text(l10n.appearanceOledForAutoLabel)),
      effect: (c) => expect(c.read(oledForAutoProvider), isTrue),
    ),

    // Color
    for (final name in <String>['neutral', 'immersive', 'night'])
      _Control(
        'Color style: $name',
        writers: {'updateColorStyle'},
        columns: {'colorStyle'},
        fields: {'colorStyle'},
        act: (t) =>
            tap(t, find.byKey(ValueKey<String>('colorStyleTile-$name'))),
        effect: (c) {
          expect(c.read(colorStyleProvider), NavisColorStyle.parse(name));
          expect(
            c.read(effectiveColorStyleProvider),
            NavisColorStyle.parse(name),
          );
        },
      ),
    _Control(
      'Fine-Tune: Color intensity',
      writers: {'colorTuning'},
      columns: {'colorVividness'},
      fields: {'colorVividness'},
      act: (t) => withTuningPanel(t, () => tap(t, panelKey('color-plus'))),
      effect: (c) {
        expect(c.read(colorTuningProvider).vividness, 1);
        expect(c.read(effectiveColorTuningProvider).vividness, 1);
      },
    ),
    _Control(
      'Fine-Tune: Brightness (Dark)',
      writers: {'colorTuning'},
      columns: {'surfaceDepthDark'},
      fields: {'surfaceDepthDark'},
      act: (t) => withTuningPanel(t, () => tap(t, panelKey('brightness-plus'))),
      effect: (c) => expect(c.read(colorTuningProvider).darkDepth, -1),
    ),
    _Control(
      'Fine-Tune: Brightness (Light)',
      writers: {'colorTuning'},
      columns: {'surfaceDepthLight'},
      fields: {'surfaceDepthLight'},
      act: (t) => withTuningPanel(t, () async {
        await tap(
          t,
          find.descendant(
            of: panelKey('mode'),
            matching: find.text(l10n.appearanceThemeLight),
          ),
        );
        await tap(t, panelKey('brightness-plus'));
      }),
      effect: (c) => expect(c.read(colorTuningProvider).lightDepth, -1),
    ),
    _Control(
      'Fine-Tune: Tint (Dark)',
      writers: {'colorTuning'},
      columns: {'surfaceTintDark'},
      fields: {'surfaceTintDark'},
      act: (t) => withTuningPanel(t, () => tap(t, panelKey('tint-plus'))),
      effect: (c) => expect(c.read(colorTuningProvider).darkTint, 1),
    ),
    _Control(
      'Fine-Tune: Tint (Light)',
      writers: {'colorTuning'},
      columns: {'surfaceTintLight'},
      fields: {'surfaceTintLight'},
      act: (t) => withTuningPanel(t, () async {
        await tap(
          t,
          find.descendant(
            of: panelKey('mode'),
            matching: find.text(l10n.appearanceThemeLight),
          ),
        );
        await tap(t, panelKey('tint-plus'));
      }),
      effect: (c) => expect(c.read(colorTuningProvider).lightTint, 1),
    ),
    _Control(
      'Fine-Tune: Controls White',
      writers: {'colorTuning'},
      columns: {'controlColor'},
      fields: {'controlColor'},
      act: (t) => withTuningPanel(
        t,
        () => tap(
          t,
          find.descendant(
            of: panelKey('controls'),
            matching: find.text(l10n.appearanceColorTuningControlsWhite),
          ),
        ),
      ),
      effect: (c) =>
          expect(c.read(colorTuningProvider).controls, NavisControlColor.white),
    ),
    _Control(
      'Fine-Tune: Reset',
      writers: {'colorTuning'},
      columns: {'colorVividness'},
      fields: {'colorVividness'},
      seed: (db) =>
          db.appSettingsDao.updateColorTuning(const ColorTuning(vividness: 2)),
      act: (t) => withTuningPanel(t, () => tap(t, panelKey('reset'))),
      effect: (c) => expect(c.read(colorTuningProvider), ColorTuning.none),
    ),
    _Control(
      'Night Schedule: switch',
      writers: {'updateNightSchedule'},
      columns: {'nightScheduleEnabled'},
      fields: {'nightScheduleEnabled'},
      act: (t) => tap(t, find.text(l10n.appearanceNightScheduleLabel)),
      effect: (c) => expect(c.read(nightScheduleProvider).enabled, isTrue),
    ),
    _Control(
      'Night Schedule: start time',
      writers: {'updateNightSchedule'},
      columns: {'nightScheduleStartMinutes'},
      fields: {'nightScheduleStartMinutes'},
      seed: nightOn,
      act: (t) => pickNightTime(t, start: true, hour: 19, minute: 30),
      effect: (c) =>
          expect(c.read(nightScheduleProvider).startMinutes, 19 * 60 + 30),
    ),
    _Control(
      'Night Schedule: end time',
      writers: {'updateNightSchedule'},
      columns: {'nightScheduleEndMinutes'},
      fields: {'nightScheduleEndMinutes'},
      seed: nightOn,
      act: (t) => pickNightTime(t, start: false, hour: 6, minute: 15),
      effect: (c) =>
          expect(c.read(nightScheduleProvider).endMinutes, 6 * 60 + 15),
    ),
    _Control(
      'Accent: a preset',
      writers: {'updateColorSchemeSeed'},
      columns: {'colorSchemeSeed'},
      fields: {'colorSchemeSeed'},
      act: (t) => tap(
        t,
        find.byKey(ValueKey<String>('colorChip-preset-${presetValue(2)}')),
      ),
      effect: (c) => expect(c.read(colorSchemeSeedProvider), presetValue(2)),
    ),
    _Control(
      'Accent: Default',
      writers: {'updateColorSchemeSeed'},
      columns: {'colorSchemeSeed'},
      fields: {'colorSchemeSeed'},
      seed: (db) => db.appSettingsDao.updateColorSchemeSeed(presetValue(2)),
      act: (t) =>
          tap(t, find.byKey(const ValueKey<String>('colorChip-default'))),
      effect: (c) => expect(c.read(colorSchemeSeedProvider), isNull),
    ),
    _Control(
      'Accent: custom colour (Apply)',
      writers: {'updateColorSchemeSeed'},
      columns: {'colorSchemeSeed'},
      fields: {'colorSchemeSeed'},
      act: (t) => pickHex(t, '3366CC', l10n.appearanceColorPickerApply),
      effect: (c) => expect(c.read(colorSchemeSeedProvider), 0xFF3366CC),
    ),
    _Control(
      'Accent: custom colour (Save as preset)',
      writers: {'updateColorSchemeSeed', 'updateCustomColorPresets'},
      columns: {'colorSchemeSeed', 'customColorPresets'},
      fields: {'colorSchemeSeed'},
      act: (t) => pickHex(t, '3366CC', l10n.appearanceColorPickerSave),
      effect: (c) {
        expect(c.read(colorSchemeSeedProvider), 0xFF3366CC);
        expect(settings().customColorPresets, [0xFF3366CC]);
      },
    ),
    _Control(
      'Accent: delete the selected custom preset',
      writers: {'updateCustomColorPresets', 'updateColorSchemeSeed'},
      columns: {'colorSchemeSeed', 'customColorPresets'},
      fields: {'colorSchemeSeed'},
      seed: (db) async {
        await db.appSettingsDao.updateCustomColorPresets('[${0xFF3366CC}]');
        await db.appSettingsDao.updateColorSchemeSeed(0xFF3366CC);
      },
      act: (t) async {
        await t.longPress(
          find.byKey(ValueKey<String>('colorChip-custom-${0xFF3366CC}')),
        );
        await settle(t);
        await tap(t, find.text(l10n.appearanceColorDeletePreset).last);
      },
      effect: (c) {
        expect(c.read(colorSchemeSeedProvider), isNull);
        expect(settings().customColorPresets, isEmpty);
      },
    ),
    _Control(
      'Accent: delete another custom preset',
      writers: {'updateCustomColorPresets'},
      columns: {'customColorPresets'},
      seed: (db) async {
        await db.appSettingsDao.updateCustomColorPresets('[${0xFF3366CC}]');
      },
      act: (t) async {
        await t.longPress(
          find.byKey(ValueKey<String>('colorChip-custom-${0xFF3366CC}')),
        );
        await settle(t);
        await tap(t, find.text(l10n.appearanceColorDeletePreset).last);
      },
      effect: (c) => expect(settings().customColorPresets, isEmpty),
    ),
    _Control(
      'Dynamic Album Color',
      writers: {'updateDynamicAlbumColorEnabled'},
      columns: {'dynamicAlbumColorEnabled'},
      fields: {'dynamicAlbumColorEnabled'},
      act: (t) => tap(t, find.text(l10n.appearanceDynamicAlbumColorLabel)),
      effect: (c) => expect(c.read(dynamicAlbumColorEnabledProvider), isTrue),
    ),
    _Control(
      'Album Art Shade',
      writers: {'updateAlbumArtShade'},
      columns: {'albumArtShade'},
      fields: {'albumArtShade'},
      act: (t) =>
          tap(t, find.byKey(const ValueKey<String>('albumArtShadeSwitch'))),
      effect: (c) {
        expect(c.read(albumArtShadeProvider), isTrue);
        expect(c.read(albumTitleShadeModeProvider), AlbumTitleShade.dark);
      },
    ),
    _Control(
      'Album Art Shade: Use Cover Color',
      writers: {'updateAlbumArtColoredShade'},
      columns: {'albumArtColoredShade'},
      fields: {'albumArtColoredShade'},
      seed: (db) => db.appSettingsDao.updateAlbumArtShade(enabled: true),
      act: (t) => tap(
        t,
        find.byKey(const ValueKey<String>('albumArtCoverColorSwitch')),
      ),
      effect: (c) {
        expect(c.read(albumArtColoredShadeProvider), isTrue);
        expect(c.read(albumTitleShadeModeProvider), AlbumTitleShade.color);
      },
    ),

    // Shape & Layout
    _Control(
      'Flat Surfaces',
      writers: {'updateFlatSurfaces'},
      columns: {'flatSurfaces'},
      fields: {'flatSurfaces'},
      act: (t) => tap(t, find.text(l10n.appearanceFlatSurfacesLabel)),
      effect: (c) => expect(c.read(flatSurfacesProvider), isTrue),
    ),
    for (final (name, key, test)
        in <(String, String, bool Function(FlatAreas))>[
          (
            'surfaces',
            'flatAreaSurfaces',
            (a) => !a.surfaces && a.nowPlaying && a.artworkText,
          ),
          (
            'Now Playing',
            'flatAreaNowPlaying',
            (a) => a.surfaces && !a.nowPlaying && a.artworkText,
          ),
          (
            'text over artwork',
            'flatAreaArtworkText',
            (a) => a.surfaces && a.nowPlaying && !a.artworkText,
          ),
        ])
      _Control(
        'Flat area: $name',
        writers: {'updateFlatAreas'},
        columns: {'flatAreas'},
        fields: {'flatAreas'},
        seed: (db) => db.appSettingsDao.updateFlatSurfaces(enabled: true),
        act: (t) => tap(t, find.byKey(ValueKey<String>(key))),
        effect: (c) => expect(test(c.read(flatAreasProvider)), isTrue),
      ),
    for (final (name, label) in <(String, String)>[
      ('soft', l10n.appearanceCornerStyleSoft),
      ('square', l10n.appearanceCornerStyleSquare),
    ])
      _Control(
        'Corner style: $name',
        writers: {'updateCornerStyle'},
        columns: {'cornerStyle'},
        fields: {'cornerStyle'},
        act: (t) => tap(t, inSelector('cornerStyleSelector', label)),
        effect: (c) => expect(c.read(cornerStyleProvider).name, name),
      ),
    _Control(
      'Corner style: Pill',
      writers: {'updateCornerStyle'},
      columns: {'cornerStyle'},
      fields: {'cornerStyle'},
      seed: (db) => db.appSettingsDao.updateCornerStyle('square'),
      act: (t) => tap(
        t,
        inSelector('cornerStyleSelector', l10n.appearanceCornerStyleRounded),
      ),
      effect: (c) => expect(c.read(cornerStyleProvider).name, 'rounded'),
    ),
    _Control(
      'Cover art shape: Rounded',
      writers: {'updateCoverArtShape'},
      columns: {'coverArtShape'},
      fields: {'coverArtShape'},
      act: (t) => tap(
        t,
        shape(l10n.appearanceCoverArtShapeSubLabel, l10n.shapeRounded),
      ),
      effect: (c) => expect(c.read(coverArtShapeProvider), 'rounded'),
    ),
    _Control(
      'Cover art shape: Square',
      writers: {'updateCoverArtShape'},
      columns: {'coverArtShape'},
      fields: {'coverArtShape'},
      seed: (db) => db.appSettingsDao.updateCoverArtShape('rounded'),
      act: (t) =>
          tap(t, shape(l10n.appearanceCoverArtShapeSubLabel, l10n.shapeSquare)),
      effect: (c) => expect(c.read(coverArtShapeProvider), 'square'),
    ),
    for (final (name, label) in <(String, String)>[
      ('square', l10n.shapeSquare),
      ('circle', l10n.shapeCircle),
    ])
      _Control(
        'Now Playing art shape: $name',
        writers: {'updateNowPlayingArtShape'},
        columns: {'nowPlayingArtShape'},
        fields: {'nowPlayingArtShape'},
        act: (t) => tap(t, shape(l10n.appearanceNpArtShapeLabel, label)),
        effect: (c) => expect(c.read(nowPlayingArtShapeProvider), name),
      ),
    for (final (name, label) in <(String, String)>[
      ('square', l10n.shapeSquare),
      ('rounded', l10n.shapeRounded),
    ])
      _Control(
        'Artist card shape: $name',
        writers: {'updateArtistCardShape'},
        columns: {'artistCardShape'},
        fields: {'artistCardShape'},
        act: (t) => tap(t, shape(l10n.appearanceArtistCardShapeLabel, label)),
        effect: (c) => expect(c.read(artistCardShapeProvider), name),
      ),
    for (final (name, label) in <(String, String)>[
      ('small', l10n.appearanceArtworkSizeSmall),
      ('medium', l10n.appearanceArtworkSizeMedium),
      ('large', l10n.appearanceArtworkSizeLarge),
    ])
      _Control(
        'Artwork size: $name',
        writers: {'updateGridArtworkSize'},
        columns: {'gridArtworkSize'},
        fields: {'gridArtworkSize'},
        act: (t) => tap(t, find.widgetWithText(ChoiceChip, label)),
        effect: (c) => expect(c.read(gridArtworkSizeProvider).name, name),
      ),
    _Control(
      'Artwork size: Auto',
      writers: {'updateGridArtworkSize'},
      columns: {'gridArtworkSize'},
      fields: {'gridArtworkSize'},
      seed: (db) => db.appSettingsDao.updateGridArtworkSize('large'),
      act: (t) => tap(
        t,
        find.widgetWithText(ChoiceChip, l10n.appearanceGridDensityAuto),
      ),
      effect: (c) => expect(c.read(gridArtworkSizeProvider).name, 'auto'),
    ),
    _Control(
      'Density: Compact',
      writers: {'updateDensity'},
      columns: {'homeDensity'},
      fields: {'density'},
      act: (t) =>
          tap(t, inSelector('densitySelector', l10n.appearanceDensityCompact)),
      effect: (c) => expect(c.read(densityProvider).storageKey, 'compact'),
    ),
    _Control(
      'Density: Comfortable',
      writers: {'updateDensity'},
      columns: {'homeDensity'},
      fields: {'density'},
      seed: (db) => db.appSettingsDao.updateDensity(NavisDensity.compact),
      act: (t) => tap(
        t,
        inSelector('densitySelector', l10n.appearanceDensityComfortable),
      ),
      effect: (c) => expect(c.read(densityProvider).storageKey, 'comfortable'),
    ),
    _Control(
      'Artist view: List',
      writers: {'updateArtistViewMode'},
      columns: {'artistViewMode'},
      fields: {'artistViewMode'},
      act: (t) => tap(t, find.text(l10n.appearanceArtistViewModeList)),
      effect: (c) => expect(c.read(artistViewModeProvider), 'list'),
    ),
    _Control(
      'Artist view: Grid',
      writers: {'updateArtistViewMode'},
      columns: {'artistViewMode'},
      fields: {'artistViewMode'},
      seed: (db) => db.appSettingsDao.updateArtistViewMode('list'),
      act: (t) => tap(t, find.text(l10n.appearanceArtistViewModeGrid)),
      effect: (c) => expect(c.read(artistViewModeProvider), 'grid'),
    ),

    // Now Playing
    for (final (name, label) in <(String, String)>[
      ('artwork', l10n.appearanceNowPlayingBackgroundArtwork),
      ('plain', l10n.appearanceNowPlayingBackgroundPlain),
    ])
      _Control(
        'Now Playing background: $name',
        writers: {'updateNowPlayingBackground'},
        columns: {'nowPlayingBackground'},
        fields: {'nowPlayingBackground'},
        act: (t) => tap(t, inSelector('nowPlayingBackgroundSelector', label)),
        effect: (c) =>
            expect(c.read(nowPlayingBackgroundProvider).storageKey, name),
      ),
    _Control(
      'Now Playing background: Art-Tinted',
      writers: {'updateNowPlayingBackground'},
      columns: {'nowPlayingBackground'},
      fields: {'nowPlayingBackground'},
      seed: (db) => db.appSettingsDao.updateNowPlayingBackground('plain'),
      act: (t) => tap(
        t,
        inSelector(
          'nowPlayingBackgroundSelector',
          l10n.appearanceNowPlayingBackgroundTinted,
        ),
      ),
      effect: (c) =>
          expect(c.read(nowPlayingBackgroundProvider).storageKey, 'tinted'),
    ),

    // Not part of a Look: the Look must stay selected.
    _Control(
      'Home: automatic recommendations',
      writers: {'updateHomeRecommendationsAutoAdvance'},
      columns: {'homeRecommendationsAutoAdvance'},
      act: (t) async {
        await expandGroup(t, l10n.appearanceHomeSectionsLabel);
        await tap(t, find.text(l10n.appearanceRecommendationsAutoAdvance));
      },
      effect: (c) =>
          expect(c.read(homeRecommendationsAutoAdvanceProvider), isTrue),
    ),
    _Control(
      'Home: hide a section',
      writers: {'updateHomeSectionsHidden'},
      columns: {'homeSectionsHidden'},
      act: (t) async {
        await expandGroup(t, l10n.appearanceHomeSectionsLabel);
        await tap(
          t,
          find
              .descendant(
                of: find.widgetWithText(
                  ListTile,
                  l10n.homeSectionRecentlyAdded,
                ),
                matching: find.byType(Switch),
              )
              .first,
        );
      },
      effect: (c) => expect(
        HomeSectionIds.resolveHidden(c.read(homeSectionsHiddenProvider)),
        contains('recently_added'),
      ),
    ),
    _Control(
      'Home: show a hidden section',
      writers: {'updateHomeSectionsHidden'},
      columns: {'homeSectionsHidden'},
      seed: (db) => db.appSettingsDao.updateHomeSectionsHidden(hiddenOnce),
      act: (t) async {
        await expandGroup(t, l10n.appearanceHomeSectionsLabel);
        await tap(
          t,
          find
              .descendant(
                of: find.widgetWithText(
                  ListTile,
                  l10n.homeSectionRecentlyAdded,
                ),
                matching: find.byType(Switch),
              )
              .first,
        );
      },
      // Nothing hidden is a saved choice, not the built-in default. Only the
      // never-seen Random Albums section stays hidden.
      effect: (c) => expect(
        HomeSectionIds.resolveHidden(c.read(homeSectionsHiddenProvider)),
        ['random_album_list'],
      ),
    ),
    _Control(
      'Home: reorder sections',
      writers: {'updateHomeSectionOrder'},
      columns: {'homeSectionOrder'},
      act: (t) async {
        await expandGroup(t, l10n.appearanceHomeSectionsLabel);
        await t.drag(
          find
              .descendant(
                of: find.widgetWithText(
                  ListTile,
                  l10n.homeSectionRecentlyAdded,
                ),
                matching: find.byIcon(Icons.drag_handle),
              )
              .first,
          const Offset(0, 120),
        );
        await settle(t);
      },
      effect: (c) => expect(
        HomeSectionIds.resolveOrder(settings().homeSectionOrder)
            .indexOf('recently_added'),
        greaterThan(HomeSectionIds.defaultOrder.indexOf('recently_added')),
      ),
    ),
    for (final (name, column, section) in <(String, String, String)>[
      ('Albums', 'showAlbumsPage', 'albums'),
      ('Liked', 'showLikedPage', 'liked'),
      ('Artists', 'showArtistsPage', 'artists'),
      ('Playlists', 'showPlaylistsPage', 'playlists'),
      ('Radio', 'showRadioPage', 'radio'),
    ])
      _Control(
        'Pages: hide $name',
        writers: {
          'updateShowAlbumsPage',
          'updateShowLikedPage',
          'updateShowArtistsPage',
          'updateShowPlaylistsPage',
          'updateShowRadioPage',
        },
        columns: {column},
        act: (t) async {
          await expandGroup(t, l10n.appearancePagesSectionLabel);
          await tap(
            t,
            find.descendant(
              of: find.byKey(ValueKey<String>('library-page-$section')),
              matching: find.byType(Switch),
            ),
          );
        },
        effect: (c) => expect(
          c.read(visibleLibrarySectionsProvider).map((s) => s.name),
          isNot(contains(section)),
        ),
      ),
    _Control(
      'Pages: reorder',
      writers: {'updateLibraryPageOrder'},
      columns: {'libraryPageOrder'},
      act: (t) async {
        await expandGroup(t, l10n.appearancePagesSectionLabel);
        await t.drag(
          find.descendant(
            of: find.byKey(const ValueKey<String>('library-page-albums')),
            matching: find.byIcon(Icons.drag_handle),
          ),
          const Offset(0, 120),
        );
        await settle(t);
      },
      effect: (c) =>
          expect(c.read(libraryPageOrderProvider).first.name, isNot('albums')),
    ),
    for (final (name, label, value) in <(String, String, String)>[
      ('Narrow', l10n.desktopNavbarStyleNarrow, 'compact'),
      ('Icons', l10n.desktopNavbarStyleIcons, 'icons'),
    ])
      _Control(
        'Desktop navigation: $name',
        desktop: true,
        writers: {'updateDesktopNavbarStyle'},
        columns: {'desktopNavbarStyle'},
        act: (t) async {
          await expandGroup(t, l10n.desktopNavbarSectionLabel);
          await tap(t, find.text(label));
        },
        effect: (c) => expect(c.read(desktopNavbarStyleProvider), value),
      ),
    _Control(
      'Desktop navigation: Collapse Sidebar',
      desktop: true,
      writers: {'updateDesktopNavbarAutohide'},
      columns: {'desktopNavbarAutohide'},
      act: (t) async {
        await expandGroup(t, l10n.desktopNavbarSectionLabel);
        await tap(t, find.text(l10n.desktopNavbarAutohideLabel));
      },
      effect: (c) => expect(c.read(desktopNavbarAutohideProvider), isTrue),
    ),
  ];

  // ── the audit ────────────────────────────────────────────────────────────

  group('Appearance controls', () {
    for (final control in controls) {
      testWidgets(control.name, (tester) async {
        await pumpPage(tester, seed: control.seed, desktop: control.desktop);
        await saveBaseLook(tester);
        expect(pickerText(tester), 'Base', reason: 'starts on the saved Look');
        final rowBefore = await row(tester);
        final snapshotBefore = snapshot();

        await control.act(tester);

        // 1. It writes the intended settings, and only those.
        expect(
          changed(rowBefore, await row(tester)),
          control.columns,
          reason: 'columns written',
        );
        // 2. The app-level state reads the new value.
        control.effect(container);
        final snapshotAfter = snapshot();
        expect(
          changed(snapshotBefore, snapshotAfter),
          control.fields,
          reason: 'Look fields changed',
        );

        // 3. A captured change makes the Look Custom and remembers the
        // origin, also after leaving the page and coming back.
        final captured = control.fields.isNotEmpty;
        final label = captured ? 'Base*' : 'Base';
        expect(pickerText(tester), label);
        await reenter(tester, desktop: control.desktop);
        expect(pickerText(tester), label);
        expect(looks().originLookId, looks().looks.single.id);

        // 4. Update is offered exactly then, and saving selects the Look.
        await openLookMenu(tester);
        expect(
          find.byKey(const ValueKey<String>('appearanceLookUpdate')),
          captured ? findsOneWidget : findsNothing,
        );
        if (captured) {
          expect(find.text('Update “Base”'), findsOneWidget);
          await tap(
            tester,
            find.byKey(const ValueKey<String>('appearanceLookUpdate')),
          );
          expect(pickerText(tester), 'Base');
          expect(
            looks().looks.single.snapshot,
            AppearanceSnapshot.capture(settings()),
          );
          expect(looks().selectedLookId, looks().looks.single.id);
        }
      });
    }
  });

  group('coverage guard', () {
    final screen = File(
      'lib/src/features/settings/presentation/appearance_settings_screen.dart',
    ).readAsStringSync();

    test('every writer on the Appearance page has a row', () {
      final onPage = RegExp(r'\.(update[A-Z]\w*)\(')
          .allMatches(screen)
          .map((m) => m.group(1)!);
      final covered = {for (final c in controls) ...c.writers};
      // The language picker needs a compile-time flag and a second locale;
      // neither exists, so it is not reachable (see the page).
      const unreachable = {'updateAppLocale'};
      expect(
        onPage.toSet().difference(covered).difference(unreachable),
        isEmpty,
        reason: 'a control writes a setting that no row exercises',
      );
    });

    test('every Look field has a control, except the stated ones', () {
      final fields = AppearanceSnapshot.capture(
        const AppSettingsModel.defaults(),
      ).toJson().keys.toSet();
      final covered = {for (final c in controls) ...c.fields};
      // albumGridDensity is a legacy column: nothing reads or writes it
      // outside the Look snapshot, and the page has no control for it.
      const withoutControl = {'albumGridDensity'};
      expect(fields.difference(covered), withoutControl);
      expect(covered.difference(fields), isEmpty);
    });
  });
}
