import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_panel.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_theme.dart';

class _Repository extends Mock implements SettingsRepository;

void main() {
  test('readouts show two decimals and mark retained legacy precision', () {
    expect(formatAdjustmentNumber(1, signed: false), '1.00');
    expect(formatAdjustmentNumber(1.2735, signed: false), '≈1.27');
    expect(formatAdjustmentNumber(-0.001), '≈0.00');
    expect(formatAdjustmentNumber(3.863137, approximate: false), '+3.86');
  });
  setUpAll(() => registerFallbackValue(const PlaybackAdjustments()));
  late _Repository repository;
  late AppNoticeController notices;
  setUp(() {
    repository = _Repository();
    notices = AppNoticeController();
    addTearDown(notices.dispose);
    when(
      () => repository.savePlaybackAdjustments(
        values: any(named: 'values'),
        selectedPresetId: any(named: 'selectedPresetId'),
        presets: any(named: 'presets'),
      ),
    ).thenAnswer((_) async {});
  });

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool pitchSupported = true,
    double textScale = 1,
    AsyncValue<AppSettingsModel> settings = const AsyncData(
      AppSettingsModel.defaults(),
    ),
    bool settle = true,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(settings),
        settingsRepositoryProvider.overrideWithValue(repository),
        audioHandlerProvider.overrideWithValue(null),
        playbackAdjustmentCapabilitiesProvider.overrideWithValue(
          pitchSupported
              ? PlaybackAdjustmentCapabilities.android
              : const PlaybackAdjustmentCapabilities(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      AppNoticeScope(
        notifier: notices,
        child: UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: PlaybackAdjustmentPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return container;
  }

  String presetText(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('playbackPresetDropdown')),
          matching: find.byType(TextField),
        ),
      )
      .controller!
      .text;

  Future<void> presetAction(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(const ValueKey('playbackPresetActions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  Future<void> choosePreset(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('playbackPresetDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('unsupported saved presets can still be deleted', (tester) async {
    final container = await mount(
      tester,
      pitchSupported: false,
      settings: AsyncData(
        const AppSettingsModel.defaults().copyWith(
          playbackPresets: const [
            PlaybackPreset(
              id: 'old',
              name: 'Old pitch',
              values: PlaybackAdjustments(pitchSemitones: 3),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('playbackPresetActions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete “Old pitch”'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playbackPresetDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.presets,
      isEmpty,
    );
  });

  testWidgets('preset deletion persistence failure shows an app notice', (
    tester,
  ) async {
    await mount(
      tester,
      settings: AsyncData(
        const AppSettingsModel.defaults().copyWith(
          playbackPresets: const [
            PlaybackPreset(
              id: 'old',
              name: 'Old',
              values: PlaybackAdjustments(),
            ),
          ],
          selectedPlaybackPresetId: 'old',
        ),
      ),
    );
    when(
      () => repository.savePlaybackAdjustments(
        values: any(named: 'values'),
        selectedPresetId: any(named: 'selectedPresetId'),
        presets: any(named: 'presets'),
      ),
    ).thenThrow(StateError('Fixture write failure'));
    await presetAction(tester, 'playbackPresetDelete');
    await tester.tap(find.byKey(const ValueKey('playbackPresetDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(
      notices.notice?.message,
      'Could not delete the preset. It may have changed or could not be saved. Try again.',
    );
  });

  testWidgets(
    'buttons, fractional dragging, exact input and reset are independent',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = await mount(tester);
      await tester.tap(find.byKey(const ValueKey('adjustment-speed-plus')));
      await tester.pumpAndSettle();
      expect(
        container
            .read(playbackAdjustmentsProvider)
            .requireValue
            .values
            .speedPercent,
        closeTo(10, 0.000001),
      );
      await tester.drag(
        find.byKey(const ValueKey('adjustment-pitch-ruler')),
        const Offset(-37, 0),
      );
      await tester.pumpAndSettle();
      final pitch = container
          .read(playbackAdjustmentsProvider)
          .requireValue
          .values
          .pitchSemitones;
      expect(pitch, greaterThan(0));
      expect(pitch % 1, isNot(0));
      await tester.tap(find.byKey(const ValueKey('adjustment-speed-value')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('adjustmentExactInput')),
        '0,99',
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(
        container
            .read(playbackAdjustmentsProvider)
            .requireValue
            .values
            .speedPercent,
        closeTo(-1, 0.000001),
      );
      expect(
        container
            .read(playbackAdjustmentsProvider)
            .requireValue
            .values
            .pitchSemitones,
        pitch,
      );
      await tester.tap(find.byKey(const ValueKey('adjustment-speed-chip-1')));
      await tester.pumpAndSettle();
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.values.speed,
        1,
      );
      expect(
        container
            .read(playbackAdjustmentsProvider)
            .requireValue
            .values
            .pitchSemitones,
        pitch,
      );
      await tester.ensureVisible(find.text('Reset Speed & Pitch'));
      await tester.tap(find.text('Reset Speed & Pitch'));
      await tester.pumpAndSettle();
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.values.isNone,
        isTrue,
      );
      expect(find.byType(Slider), findsNothing);
    },
  );

  testWidgets('creates a named preset, edits as Custom and saves explicitly', (
    tester,
  ) async {
    final container = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('adjustment-speed-plus')));
    await tester.pumpAndSettle();
    await presetAction(tester, 'playbackPresetSaveNew');
    await tester.enterText(
      find.byKey(const ValueKey('playbackPresetNameInput')),
      'Nightcore',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final state = container.read(playbackAdjustmentsProvider).requireValue;
    expect(state.presets.single.name, 'Nightcore');
    expect(presetText(tester), 'Nightcore');
    await tester.tap(find.byKey(const ValueKey('adjustment-speed-plus')));
    await tester.pumpAndSettle();
    expect(presetText(tester), 'Custom');
    expect(
      container
          .read(playbackAdjustmentsProvider)
          .requireValue
          .presets
          .single
          .values
          .speed,
      1.1,
    );
    await presetAction(tester, 'playbackPresetUpdate');
    expect(
      container
          .read(playbackAdjustmentsProvider)
          .requireValue
          .presets
          .single
          .values
          .speed,
      1.2,
    );
    expect(presetText(tester), 'Nightcore');
  });

  testWidgets('unsupported pitch hides pitch controls and keeps speed', (
    tester,
  ) async {
    await mount(tester, pitchSupported: false);
    expect(find.byKey(const ValueKey('adjustment-pitch-ruler')), findsNothing);
    expect(find.byKey(const ValueKey('playback-pitch-lock')), findsNothing);
    expect(
      find.text('Pitch control is unavailable on this audio backend.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('adjustment-speed-minus')));
    await tester.pumpAndSettle();
    expect(find.text('0.90×'), findsOneWidget);
  });

  testWidgets(
    'speed resets through its 1× chip; pitch offers Reset once changed',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = await mount(tester);
      PlaybackAdjustments values() =>
          container.read(playbackAdjustmentsProvider).requireValue.values;
      expect(
        find.byKey(const ValueKey('adjustment-speed-reset')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('adjustment-pitch-reset')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('adjustment-speed-plus')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('adjustment-pitch-plus')),
      );
      await tester.tap(find.byKey(const ValueKey('adjustment-pitch-plus')));
      await tester.pumpAndSettle();
      expect(values().pitchSemitones, 1);
      expect(
        find.byKey(const ValueKey('adjustment-speed-reset')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('adjustment-pitch-reset')));
      await tester.pumpAndSettle();
      expect(values().pitchSemitones, 0);
      expect(values().speedPercent, closeTo(10, 0.000001));
      expect(
        find.byKey(const ValueKey('adjustment-pitch-reset')),
        findsNothing,
      );
      // Linked pitch follows the 1.1× speed, but it is not the user's to
      // reset there.
      await tester.tap(find.byKey(const ValueKey('playback-pitch-lock')));
      await tester.pumpAndSettle();
      expect(values().pitchSemitones, isNot(0));
      expect(
        find.byKey(const ValueKey('adjustment-pitch-reset')),
        findsNothing,
      );
    },
  );

  testWidgets('speed and pitch rulers keep one width, linked or not', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await mount(tester);
    double width(String key) => tester.getSize(find.byKey(ValueKey(key))).width;
    expect(width('adjustment-pitch-ruler'), width('adjustment-speed-ruler'));
    await tester.tap(find.byKey(const ValueKey('playback-pitch-lock')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('adjustment-pitch-minus')), findsNothing);
    expect(width('adjustment-pitch-ruler'), width('adjustment-speed-ruler'));
  });

  testWidgets('every chip or preset change glides the ruler with haptics', (
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
    await mount(tester);

    Future<void> pumpFrames() async {
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
    }

    for (final pick in <String>['1.5', '0.75', '1', '1.25', '0.5']) {
      haptics.clear();
      await tester.tap(find.byKey(ValueKey('adjustment-speed-chip-$pick')));
      await tester.pump();
      await pumpFrames();
      expect(haptics, isNotEmpty, reason: 'chip $pick glided without ticks');
    }

    haptics.clear();
    await choosePreset(tester, 'Normal');
    await pumpFrames();
    expect(haptics, isNotEmpty, reason: 'preset glided without ticks');
  });

  testWidgets('speed chips select common speeds and mark the current one', (
    tester,
  ) async {
    final container = await mount(tester);
    ChoiceChip chip(String label) => tester.widget<ChoiceChip>(
      find.byKey(ValueKey('adjustment-speed-chip-$label')),
    );
    expect(chip('1').selected, isTrue);
    // Five picks, symmetric around 1×, which sits in the middle of the row.
    expect(find.byKey(const ValueKey('adjustment-speed-chip-2')), findsNothing);
    final slow = tester.getCenter(
      find.byKey(const ValueKey('adjustment-speed-chip-0.5')),
    );
    final normal = tester.getCenter(
      find.byKey(const ValueKey('adjustment-speed-chip-1')),
    );
    final fast = tester.getCenter(
      find.byKey(const ValueKey('adjustment-speed-chip-1.5')),
    );
    expect(normal.dx, closeTo((slow.dx + fast.dx) / 2, 0.5));
    expect(normal.dy, slow.dy);
    await tester.tap(find.byKey(const ValueKey('adjustment-speed-chip-1.5')));
    await tester.pumpAndSettle();
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.values.speed,
      1.5,
    );
    expect(chip('1.5').selected, isTrue);
    expect(chip('1').selected, isFalse);
    verify(
      () => repository.savePlaybackAdjustments(
        values: const PlaybackAdjustments(speed: 1.5),
        selectedPresetId: null,
      ),
    ).called(1);
  });

  testWidgets('preset dropdown shows Normal, Custom edits and reselects', (
    tester,
  ) async {
    final container = await mount(tester);
    expect(
      find.byType(ChoiceChip).evaluate().where((e) {
        final key = e.widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('playbackPreset');
      }),
      isEmpty,
    );
    expect(presetText(tester), 'Normal');
    await tester.tap(find.byKey(const ValueKey('adjustment-speed-plus')));
    await tester.pumpAndSettle();
    expect(presetText(tester), 'Custom');
    await choosePreset(tester, 'Normal');
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.values.isNone,
      isTrue,
    );
    expect(presetText(tester), 'Normal');
  });

  testWidgets('presets the backend cannot play are disabled', (tester) async {
    await mount(
      tester,
      pitchSupported: false,
      settings: const AsyncData(AppSettingsModel.defaults()).whenData(
        (settings) => settings.copyWith(
          playbackPresets: const [
            PlaybackPreset(
              id: 'user:deep',
              name: 'Deep',
              values: PlaybackAdjustments(pitchSemitones: -3),
            ),
          ],
        ),
      ),
    );
    final menu = tester.widget<DropdownMenu<String>>(
      find.byKey(const ValueKey('playbackPresetDropdown')),
    );
    final deep = menu.dropdownMenuEntries.singleWhere(
      (entry) => entry.value == 'user:deep',
    );
    expect(deep.enabled, isFalse);
  });

  testWidgets('holding a stepper repeats and saves once on release', (
    tester,
  ) async {
    final container = await mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('adjustment-speed-plus'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 130));
    await tester.pump(const Duration(milliseconds: 130));
    await gesture.up();
    await tester.pumpAndSettle();
    final speed = container
        .read(playbackAdjustmentsProvider)
        .requireValue
        .values
        .speed;
    expect(speed, greaterThanOrEqualTo(1.3 - 1e-9));
    verify(
      () => repository.savePlaybackAdjustments(
        values: any(named: 'values'),
        selectedPresetId: any(named: 'selectedPresetId'),
        presets: any(named: 'presets'),
      ),
    ).called(1);
    await tester.pump(const Duration(seconds: 1));
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.values.speed,
      speed,
    );
  });

  testWidgets('range text appears only at a limit and wording is clear', (
    tester,
  ) async {
    final container = await mount(tester);
    expect(find.textContaining('Available range'), findsNothing);
    expect(find.text('Pitch Lock'), findsOneWidget);
    expect(find.text('Match pitch to speed.'), findsOneWidget);
    await container
        .read(playbackAdjustmentsProvider.notifier)
        .setValues(const PlaybackAdjustments(speed: 8));
    await tester.pumpAndSettle();
    expect(find.text('Maximum supported speed reached'), findsOneWidget);
    expect(find.textContaining('Available range'), findsOneWidget);
  });

  testWidgets('hosted panels show a close button', (tester) async {
    var closed = false;
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        settingsRepositoryProvider.overrideWithValue(repository),
        audioHandlerProvider.overrideWithValue(null),
        playbackAdjustmentCapabilitiesProvider.overrideWithValue(
          PlaybackAdjustmentCapabilities.android,
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: PlaybackAdjustmentPanel(onClose: () => closed = true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playbackAdjustmentClose')));
    expect(closed, isTrue);
  });

  testWidgets('lock follows speed, disables pitch and unlocks exact sound', (
    tester,
  ) async {
    final container = await mount(tester);
    final controller = container.read(playbackAdjustmentsProvider.notifier);
    await controller.setValues(const PlaybackAdjustments(speed: 1.25));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playback-pitch-lock')));
    await tester.pumpAndSettle();
    final linked = container
        .read(playbackAdjustmentsProvider)
        .requireValue
        .values;
    expect(linked.pitchFactor, 1.25);
    expect(find.text('+3.86 semitones'), findsOneWidget);
    // Linked pitch: a link icon on the heading instead of a caption, no
    // inert step buttons, and a read-only ruler shown at full contrast.
    expect(find.text('Follows playback speed'), findsNothing);
    expect(
      find.byKey(const ValueKey('adjustment-pitch-linked')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('adjustment-pitch-minus')), findsNothing);
    expect(find.byKey(const ValueKey('adjustment-pitch-plus')), findsNothing);
    final lockedRuler = tester.widget<AdjustmentRuler>(
      find.byKey(const ValueKey('adjustment-pitch-ruler')),
    );
    expect(lockedRuler.enabled, isFalse);
    expect(lockedRuler.readOnly, isTrue);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('adjustment-pitch-value')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('adjustment-speed-chip-1')));
    await tester.pumpAndSettle();
    expect(
      container
          .read(playbackAdjustmentsProvider)
          .requireValue
          .values
          .lockPitchToSpeed,
      isTrue,
    );
    expect(
      container
          .read(playbackAdjustmentsProvider)
          .requireValue
          .values
          .pitchSemitones,
      0,
    );
    await controller.setValues(linked);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playback-pitch-lock')));
    await tester.pumpAndSettle();
    expect(
      container
          .read(playbackAdjustmentsProvider)
          .requireValue
          .values
          .pitchSemitones,
      linked.pitchSemitones,
    );
    expect(find.byKey(const ValueKey('adjustment-pitch-linked')), findsNothing);
    expect(
      find.byKey(const ValueKey('adjustment-pitch-minus')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('adjustment-speed-plus')));
    await tester.pumpAndSettle();
    expect(
      container
          .read(playbackAdjustmentsProvider)
          .requireValue
          .values
          .pitchFactor,
      closeTo(1.25, 1e-14),
    );
  });

  testWidgets('exact precision and limits fail inline without changing sound', (
    tester,
  ) async {
    final container = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('adjustment-speed-value')));
    await tester.pumpAndSettle();
    for (final invalid in ['1.234', '0', '8.01']) {
      await tester.enterText(
        find.byKey(const ValueKey('adjustmentExactInput')),
        invalid,
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('adjustmentExactInput')),
        findsOneWidget,
      );
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.values.isNone,
        isTrue,
      );
    }
    await tester.enterText(
      find.byKey(const ValueKey('adjustmentExactInput')),
      '8,00',
    );
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.values.speed,
      8,
    );
    expect(
      tester
          .widget<IconButton>(
            find.descendant(
              of: find.byKey(const ValueKey('adjustment-speed-plus')),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Maximum supported speed reached'), findsOneWidget);
  });

  testWidgets(
    'long presets can be renamed and deleted without changing sound',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = await mount(tester);
      final controller = container.read(playbackAdjustmentsProvider.notifier);
      const values = PlaybackAdjustments(speed: 1.2537, pitchSemitones: 2.34);
      await controller.setValues(values);
      final name = List.filled(30, 'Nightcore ').join();
      await controller.savePreset(name);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(presetText(tester), name.trim());
      await presetAction(tester, 'playbackPresetRename');
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const ValueKey('playbackPresetNameInput')),
        'Fast',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        container
            .read(playbackAdjustmentsProvider)
            .requireValue
            .presets
            .single
            .name,
        'Fast',
      );
      await presetAction(tester, 'playbackPresetDelete');
      // Deleting asks first; cancelling keeps the preset.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.presets,
        hasLength(1),
      );
      await presetAction(tester, 'playbackPresetDelete');
      await tester.tap(
        find.byKey(const ValueKey('playbackPresetDeleteConfirm')),
      );
      await tester.pumpAndSettle();
      final state = container.read(playbackAdjustmentsProvider).requireValue;
      expect(state.values, values);
      expect(state.presets, isEmpty);
      expect(presetText(tester), 'Custom');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard, focused wheel and semantics allow fractional changes',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final container = await mount(tester);
      final ruler = find.byKey(const ValueKey('adjustment-speed-ruler'));
      await tester.tap(ruler);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(
        container
            .read(playbackAdjustmentsProvider)
            .requireValue
            .values
            .speedPercent,
        closeTo(-9, 1e-6),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(ruler),
          scrollDelta: const Offset(0, 12),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        container
            .read(playbackAdjustmentsProvider)
            .requireValue
            .values
            .speedPercent,
        closeTo(-8, 1e-6),
      );
      final node = tester.getSemantics(ruler);
      expect(
        node.getSemanticsData().hasAction(ui.SemanticsAction.decrease),
        isTrue,
      );
      tester.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          type: ui.SemanticsAction.decrease,
          viewId: tester.view.viewId,
          nodeId: node.id,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        container
            .read(playbackAdjustmentsProvider)
            .requireValue
            .values
            .speedPercent,
        closeTo(-9, 1e-6),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.values.isNone,
        isTrue,
      );
      semantics.dispose();
    },
  );

  testWidgets('dismissal flushes pending values before debounce expires', (
    tester,
  ) async {
    final container = await mount(tester);
    const values = PlaybackAdjustments(speed: 1.2345, pitchSemitones: -2.34);
    await container
        .read(playbackAdjustmentsProvider.notifier)
        .setValues(values);
    verifyNever(
      () => repository.savePlaybackAdjustments(
        values: any(named: 'values'),
        selectedPresetId: any(named: 'selectedPresetId'),
        presets: any(named: 'presets'),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    verify(
      () => repository.savePlaybackAdjustments(
        values: values,
        selectedPresetId: null,
      ),
    ).called(1);
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.values,
      values,
    );
  });

  testWidgets('loading failure can retry through the production controller', (
    tester,
  ) async {
    final load = Completer<AppSettingsModel>();
    when(() => repository.getSettings()).thenAnswer((_) => load.future);
    await mount(tester, settings: const AsyncLoading(), settle: false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    load.completeError(StateError('temporarily unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    when(() => repository.getSettings())
        .thenAnswer((_) async => const AppSettingsModel.defaults());
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(AdjustmentRuler), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'extreme exact values are rejected without losing current sound',
    (tester) async {
      final container = await mount(tester);
      await tester.tap(find.byKey(const ValueKey('adjustment-speed-value')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('adjustmentExactInput')),
        '1e308',
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('adjustmentExactInput')),
        findsOneWidget,
      );
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.values.isNone,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(390, 844),
    const Size(768, 1024),
    const Size(1280, 800),
  ]) {
    testWidgets('layout fits $size at enlarged text', (tester) async {
      setAdaptiveTestViewport(tester, size);
      await mount(tester, textScale: 2);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('adjustment-pitch-ruler')),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
