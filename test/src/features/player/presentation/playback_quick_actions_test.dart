import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_panel.dart';
import 'package:navis/src/features/player/presentation/playback_quick_actions.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';

import '../../../../helpers/fake_eq_controller.dart';
import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_theme.dart';

class _Repository extends Mock implements SettingsRepository {}

class _EnabledEq extends EqController {
  @override
  Future<EqState> build() async => EqState(
    configuration: EqConfiguration.flat().copyWith(enabled: true),
    presets: const [],
  );
}

void main() {
  setUpAll(() => registerFallbackValue(const PlaybackAdjustments()));
  late _Repository repository;
  setUp(() {
    repository = _Repository();
    when(
      () => repository.savePlaybackAdjustments(
        values: any(named: 'values'),
        selectedPresetId: any(named: 'selectedPresetId'),
        presets: any(named: 'presets'),
      ),
    ).thenAnswer((_) async {});
  });

  ProviderContainer container({bool eqSupported = false}) {
    final result = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        settingsRepositoryProvider.overrideWithValue(repository),
        audioHandlerProvider.overrideWithValue(null),
        playbackAdjustmentCapabilitiesProvider.overrideWithValue(
          PlaybackAdjustmentCapabilities.android,
        ),
        eqCapabilitiesProvider.overrideWithValue(
          eqSupported ? EqCapabilities.available : EqCapabilities.unavailable,
        ),
        if (eqSupported) equalizerProvider.overrideWith(_EnabledEq.new),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  Future<void> pumpButton(
    WidgetTester tester,
    ProviderContainer container, {
    required bool desktop,
    Widget button = const PlaybackSpeedQuickButton(
      key: ValueKey<String>('speedButton'),
    ),
  }) async {
    const size = Size(1280, 800);
    setAdaptiveTestViewport(tester, desktop ? size : const Size(390, 844));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: desktop,
              viewportSize: MediaQuery.sizeOf(context),
              safePadding: EdgeInsets.zero,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: button),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('speed button shows an icon, a multiplier, or a tinted icon', (
    tester,
  ) async {
    final providers = container();
    await pumpButton(tester, providers, desktop: false);
    final primary = Theme.of(
      tester.element(find.byKey(const ValueKey('speedButton'))),
    ).colorScheme.primary;
    Icon icon() => tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('speedButton')),
        matching: find.byIcon(Icons.speed),
      ),
    );
    expect(icon().color, isNull);
    expect(find.byKey(const ValueKey('playbackSpeedQuickLabel')), findsNothing);

    final controller = providers.read(playbackAdjustmentsProvider.notifier);
    await controller.setValues(const PlaybackAdjustments(speed: 1.25));
    await tester.pumpAndSettle();
    expect(find.text('1.25×'), findsOneWidget);
    expect(find.byIcon(Icons.speed), findsNothing);

    await controller.setValues(const PlaybackAdjustments(pitchSemitones: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playbackSpeedQuickLabel')), findsNothing);
    expect(icon().color, primary);
    await controller.flush();
  });

  testWidgets('speed nudges step, stop at limits, and reset only speed', (
    tester,
  ) async {
    final providers = container();
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: providers,
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    await providers.read(playbackAdjustmentsProvider.future);
    PlaybackAdjustments values() =>
        providers.read(playbackAdjustmentsProvider).requireValue.values;

    expect(
      await nudgePlaybackSpeed(capturedRef, hundredths: 10),
      PlaybackSpeedNudgeResult.changed,
    );
    expect(values().speed, closeTo(1.1, 1e-12));
    await providers
        .read(playbackAdjustmentsProvider.notifier)
        .setValues(const PlaybackAdjustments(speed: 8, lockPitchToSpeed: true));
    expect(
      await nudgePlaybackSpeed(capturedRef, hundredths: 10),
      PlaybackSpeedNudgeResult.maximumReached,
    );
    expect(
      await nudgePlaybackSpeed(capturedRef),
      PlaybackSpeedNudgeResult.changed,
    );
    expect(values(), const PlaybackAdjustments(lockPitchToSpeed: true));
    verify(
      () => repository.savePlaybackAdjustments(
        values: const PlaybackAdjustments(lockPitchToSpeed: true),
        selectedPresetId: null,
      ),
    ).called(1);
  });

  testWidgets('desktop opens an anchored popover that Escape dismisses', (
    tester,
  ) async {
    final providers = container();
    await pumpButton(tester, providers, desktop: true);
    await tester.tap(find.byKey(const ValueKey('speedButton')));
    await tester.pumpAndSettle();
    final popover = find.byKey(const ValueKey('desktopAnchoredPopover'));
    expect(popover, findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      tester.getRect(popover).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('speedButton'))).top,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('adjustment-speed-chip-1.5')));
    await tester.pumpAndSettle();
    verify(
      () => repository.savePlaybackAdjustments(
        values: const PlaybackAdjustments(speed: 1.5),
        selectedPresetId: null,
      ),
    ).called(1);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(popover, findsNothing);
    expect(find.text('1.5×'), findsOneWidget);
  });

  testWidgets('desktop popover closes on an outside click', (tester) async {
    await pumpButton(tester, container(), desktop: true);
    await tester.tap(find.byKey(const ValueKey('speedButton')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackAdjustmentPanel), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackAdjustmentPanel), findsNothing);
  });

  testWidgets('touch layouts open the panel in a bottom sheet', (
    tester,
  ) async {
    await pumpButton(tester, container(), desktop: false);
    await tester.tap(find.byKey(const ValueKey('speedButton')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('desktopAnchoredPopover')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('quickPanelClose')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackAdjustmentPanel), findsNothing);
  });

  testWidgets('disabled speed button explains why', (tester) async {
    await pumpButton(
      tester,
      container(),
      desktop: true,
      button: const PlaybackSpeedQuickButton(
        key: ValueKey<String>('speedButton'),
        enabled: false,
        disabledTooltip: 'Nothing is playing',
      ),
    );
    final button = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('speedButton')),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(button.tooltip, 'Nothing is playing');
  });

  testWidgets('equalizer button is hidden without backend support', (
    tester,
  ) async {
    await pumpButton(
      tester,
      container(),
      desktop: true,
      button: const EqualizerQuickButton(key: ValueKey<String>('eqButton')),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('eqButton')),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );
  });

  group('equalizer button', () {
    late FakeEqController fake;
    late GoRouter router;
    late ProviderContainer providers;

    Widget page(String label) => Scaffold(
      body: Column(
        children: [
          Text(label),
          const EqualizerQuickButton(key: ValueKey<String>('eqButton')),
        ],
      ),
    );

    Future<void> pumpRouter(WidgetTester tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      fake = FakeEqController(
        initial: EqState(
          configuration: EqConfiguration.flat().copyWith(enabled: true),
          presets: const [],
        ),
      );
      router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => page('Home page')),
          GoRoute(path: '/other', builder: (_, _) => page('Other page')),
          GoRoute(path: '/settings', builder: (_, _) => page('Settings page')),
          GoRoute(
            path: '/settings/equalizer',
            builder: (_, _) => page('EQ page'),
          ),
        ],
      );
      addTearDown(router.dispose);
      providers = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          settingsRepositoryProvider.overrideWithValue(repository),
          audioHandlerProvider.overrideWithValue(null),
          desktopPresentationRuntimeProvider.overrideWithValue(false),
          eqCapabilitiesProvider.overrideWithValue(EqCapabilities.available),
          equalizerProvider.overrideWith(() => fake),
        ],
      );
      addTearDown(providers.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: providers,
          child: MaterialApp.router(
            theme: testTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    String location() => router.state.uri.toString();

    testWidgets('opens the mini panel instead of the full page', (
      tester,
    ) async {
      await pumpRouter(tester);
      final button = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(const ValueKey('eqButton')),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.tooltip, 'Equalizer: Custom');
      await tester.tap(find.byKey(const ValueKey('eqButton')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('equalizerQuickPanel')),
        findsOneWidget,
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(location(), '/');
    });

    testWidgets('full page returns to the expanded player it came from', (
      tester,
    ) async {
      await pumpRouter(tester);
      providers.read(playerOverlayStackProvider.notifier).expand();
      await tester.tap(find.byKey(const ValueKey('eqButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('eq-quick-open-page')));
      await tester.pumpAndSettle();
      expect(location(), '/settings/equalizer');
      expect(find.byType(BottomSheet), findsNothing);
      expect(providers.read(playerOverlayStackProvider), isEmpty);

      // On the page, the same button is a selected Close toggle.
      final onPage = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(const ValueKey('eqButton')),
          matching: find.byType(IconButton),
        ),
      );
      expect(onPage.isSelected, isTrue);
      expect(onPage.tooltip, 'Close Equalizer');
      await tester.tap(find.byKey(const ValueKey('eqButton')));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('flush'));
      expect(location(), '/');
      expect(
        providers.read(playerOverlayStackProvider),
        [PlayerOverlayRoute.nowPlaying],
      );
    });

    testWidgets('navigating elsewhere does not re-open the player', (
      tester,
    ) async {
      await pumpRouter(tester);
      providers.read(playerOverlayStackProvider.notifier).expand();
      await tester.tap(find.byKey(const ValueKey('eqButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('eq-quick-open-page')));
      await tester.pumpAndSettle();
      router.go('/other');
      await tester.pumpAndSettle();
      expect(find.text('Other page'), findsOneWidget);
      expect(providers.read(playerOverlayStackProvider), isEmpty);
    });

    testWidgets('closing without history falls back to Settings', (
      tester,
    ) async {
      await pumpRouter(tester);
      router.go('/settings/equalizer');
      await tester.pumpAndSettle();
      expect(router.canPop(), isFalse);
      await tester.tap(find.byKey(const ValueKey('eqButton')));
      await tester.pumpAndSettle();
      expect(location(), '/settings');
      expect(find.text('Settings page'), findsOneWidget);
    });
  });
}
