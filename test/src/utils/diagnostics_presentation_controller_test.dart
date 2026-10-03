import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:navis/src/routing/desktop_commands.dart';

import '../../helpers/fake_eq_controller.dart';

import 'package:navis/src/common_widgets/navis_tooltip.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';
import 'package:path/path.dart' as p;

class _SettingsRepository extends Mock implements SettingsRepository;

void main() {
  testWidgets('player quick controls are observed and opened by the button', (
    tester,
  ) async {
    registerFallbackValue(const PlaybackAdjustments());
    final root = Directory.systemTemp.createTempSync('navis_quick_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final repository = _SettingsRepository();
    when(
      () => repository.savePlaybackAdjustments(
        values: any(named: 'values'),
        selectedPresetId: any(named: 'selectedPresetId'),
        presets: any(named: 'presets'),
      ),
    ).thenAnswer((_) async {});
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
        eqCapabilitiesProvider.overrideWithValue(EqCapabilities.unavailable),
      ],
    );
    addTearDown(container.dispose);
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () => tester.pumpAndSettle(),
    );
    await tester.pumpWidget(
      controller.wrap(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: Row(
                children: [
                  EqualizerQuickButton(
                    key: ValueKey<String>('nowPlayingEqualizerButton'),
                  ),
                  PlaybackSpeedQuickButton(
                    key: ValueKey<String>('nowPlayingSpeedButton'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await container
        .read(playbackAdjustmentsProvider.notifier)
        .setValues(const PlaybackAdjustments(speed: 1.25));
    await tester.pumpAndSettle();
    expect(controller.playbackQuickControls(), [
      {
        'key': 'nowPlayingSpeedButton',
        'kind': 'speed',
        'enabled': true,
        'label': '1.25×',
      },
    ]);
    expect(await controller.openPlaybackQuickPanel(), 'sheet');
    expect(find.byType(PlaybackAdjustmentPanel), findsOneWidget);
    await container.read(playbackAdjustmentsProvider.notifier).flush();
  });

  testWidgets('equalizer quick panel is opened and driven by its chips', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('navis_eq_quick_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final fake = FakeEqController();
    final container = ProviderContainer(
      overrides: [
        audioHandlerProvider.overrideWithValue(null),
        eqCapabilitiesProvider.overrideWithValue(EqCapabilities.available),
        equalizerProvider.overrideWith(() => fake),
      ],
    );
    addTearDown(container.dispose);
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () => tester.pumpAndSettle(),
    );
    await tester.pumpWidget(
      controller.wrap(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: EqualizerQuickButton(key: ValueKey<String>('eqButton')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.playbackQuickControls().single['kind'], 'equalizer');
    expect(
      await controller.openPlaybackQuickPanel(target: 'equalizer'),
      'sheet',
    );
    await controller.selectQuickEqualizerPreset('builtin:bass');
    expect(fake.calls, ['select:builtin:bass:true']);
    await expectLater(
      controller.selectQuickEqualizerPreset('missing'),
      throwsA(isA<DiagnosticsPresentationUnavailable>()),
    );
  });

  testWidgets('shortcut control sends the bound chord to HardwareKeyboard', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('navis_shortcut_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () => tester.pump(),
    );
    final received = <(LogicalKeyboardKey, bool)>[];
    bool handler(KeyEvent event) {
      if (event is KeyDownEvent) {
        received.add((
          event.logicalKey,
          HardwareKeyboard.instance.isControlPressed,
        ));
      }
      return false;
    }

    HardwareKeyboard.instance.addHandler(handler);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(handler));
    await tester.pumpWidget(controller.wrap(const SizedBox()));
    await controller.sendShortcut(
      defaultDesktopShortcutBindings()[DesktopCommandAction.speedUp]!,
      TargetPlatform.linux,
    );
    expect(received.last, (LogicalKeyboardKey.period, true));
    expect(HardwareKeyboard.instance.isControlPressed, isFalse);
  });

  testWidgets('popup dismissal preserves the underlying page route', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('navis_popup_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () => tester.pump(),
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      controller.wrap(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    navigator.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('EQ page'))),
    );
    await tester.pumpAndSettle();
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const AlertDialog(title: Text('Popup')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Popup'), findsOneWidget);
    await controller.dismissPopupRoutes();
    await tester.pumpAndSettle();
    expect(find.text('Popup'), findsNothing);
    expect(find.text('EQ page'), findsOneWidget);
    await controller.dismissPopupRoutes();
    expect(find.text('EQ page'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('track drag uses the actual playlist handle gesture', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('navis_track_drag_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () => tester.pump(const Duration(milliseconds: 30)),
    );
    (int, int)? reordered;
    await tester.pumpWidget(
      controller.wrap(
        MaterialApp(
          home: Scaffold(
            body: ReorderableListView(
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) => reordered = (from, to),
              children: [
                for (var i = 0; i < 3; i++)
                  AdaptiveTrackRow(
                    key: ValueKey(i),
                    title: 'Track $i',
                    actionExtent: 48,
                    actions: ReorderableDragStartListener(
                      index: i,
                      child: const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await controller.activateTrackControl(action: 'dragFirstToLast');
    await tester.pumpAndSettle();
    expect(reordered, (0, 2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('track controls are bounded to mounted rows and scroll owner', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('navis_track_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () async {},
    );
    var menus = 0;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      controller.wrap(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: [
                AdaptiveTrackRow(
                  title: 'Track',
                  actions: IconButton(
                    onPressed: () => menus++,
                    icon: const Icon(Icons.more_vert),
                  ),
                ),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      ),
    );
    await controller.activateTrackControl(action: 'more');
    expect(menus, 1);
    await controller.activateTrackControl(action: 'revealFirst');
    expect(scroll.offset, 0);
    final scrolling = controller.activateTrackControl(action: 'scrollToLast');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await scrolling;
    expect(scroll.offset, scroll.position.maxScrollExtent);
    for (final action in [
      'download',
      'downloadedTab',
      'downloadsSettingsTab',
      'customFolderOff',
      'confirmCustomFolderOff',
      'dragFirstToLast',
    ]) {
      await expectLater(
        controller.activateTrackControl(action: action),
        throwsA(isA<DiagnosticsPresentationUnavailable>()),
      );
    }
    await expectLater(
      controller.activateTrackControl(action: 'arbitraryClick'),
      throwsFormatException,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('custom folder actions only ever turn the folder off', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('navis_folder_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () async {},
    );
    final changes = <bool>[];
    var confirms = 0;
    Future<void> pumpFolder({required bool enabled}) => tester.pumpWidget(
      controller.wrap(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SwitchListTile(
                  key: const ValueKey<String>('downloadsCustomFolderSwitch'),
                  title: const Text('Custom Folder'),
                  value: enabled,
                  onChanged: changes.add,
                ),
                FilledButton(
                  key: const ValueKey<String>(
                    'downloadsCustomFolderDisableConfirm',
                  ),
                  onPressed: () => confirms++,
                  child: const Text('Turn Off'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await pumpFolder(enabled: true);
    await controller.activateTrackControl(action: 'customFolderOff');
    await controller.activateTrackControl(action: 'confirmCustomFolderOff');
    expect(changes, [false]);
    expect(confirms, 1);

    await pumpFolder(enabled: false);
    await expectLater(
      controller.activateTrackControl(action: 'customFolderOff'),
      throwsA(isA<DiagnosticsPresentationUnavailable>()),
    );
    expect(changes, [false]);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'library actions invoke only onstage album, radio and scoped shelf controls',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'navis_library_control_test_',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final controller = DiagnosticsPresentationController(
        artifactRoot: root,
        frameWaiter: () => tester.pump(),
      );
      var albums = 0;
      var pages = 0;
      var stations = 0;
      var decoys = 0;
      await tester.pumpWidget(
        controller.wrap(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Offstage(
                    child: InkWell(
                      key: const ValueKey('albumCardTapTarget'),
                      onTap: () => decoys++,
                      child: const Text('Hidden album'),
                    ),
                  ),
                  Offstage(
                    child: Card(
                      key: const ValueKey('radioStation-hidden'),
                      child: InkWell(
                        onTap: () => decoys++,
                        child: const Text('Hidden station'),
                      ),
                    ),
                  ),
                  Card(
                    key: const ValueKey('radioStation-visible'),
                    child: InkWell(
                      onTap: () => stations++,
                      child: const Text('Station'),
                    ),
                  ),
                  InkWell(
                    key: const ValueKey('albumCardTapTarget'),
                    onTap: () => albums++,
                    child: const Text('Album'),
                  ),
                  IconButton(
                    key: const ValueKey('contentShelfNextButton'),
                    onPressed: () => decoys++,
                    icon: const Icon(Icons.chevron_right),
                  ),
                  SizedBox(
                    key: const ValueKey('liked-albums-shelf'),
                    child: IconButton(
                      key: const ValueKey('contentShelfNextButton'),
                      onPressed: () => pages++,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await controller.activateLibraryControl(action: 'openFirstAlbum');
      await controller.activateLibraryControl(action: 'nextLikedAlbums');
      await controller.activateLibraryControl(
        action: 'toggleFirstRadioStation',
      );
      expect(albums, 1);
      expect(pages, 1);
      expect(stations, 1);
      expect(decoys, 0);
      await expectLater(
        controller.activateLibraryControl(action: 'arbitraryClick'),
        throwsFormatException,
      );
      await tester.pumpWidget(
        controller.wrap(const MaterialApp(home: SizedBox())),
      );
      for (final action in ['nextLikedAlbums', 'toggleFirstRadioStation']) {
        await expectLater(
          controller.activateLibraryControl(action: action),
          throwsA(isA<DiagnosticsPresentationUnavailable>()),
        );
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('playback setting toggle flips only the keyed switch', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync(
      'navis_playback_setting_test_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () => tester.pump(),
    );
    final changes = <bool>[];
    var decoys = 0;
    await tester.pumpWidget(
      controller.wrap(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SwitchListTile(
                  value: true,
                  onChanged: (_) => decoys++,
                  title: const Text('Other switch'),
                ),
                SwitchListTile(
                  key: const ValueKey('playbackSettingsScrobbleToggle'),
                  value: true,
                  onChanged: changes.add,
                  title: const Text('Enable Scrobbling'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await controller.togglePlaybackSetting(setting: 'scrobble');
    expect(changes, [false]);
    expect(decoys, 0);
    await expectLater(
      controller.togglePlaybackSetting(setting: 'gapless'),
      throwsFormatException,
    );
    await tester.pumpWidget(
      controller.wrap(const MaterialApp(home: SizedBox())),
    );
    await expectLater(
      controller.togglePlaybackSetting(setting: 'scrobble'),
      throwsA(isA<DiagnosticsPresentationUnavailable>()),
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('tooltip control drives real hover below excluded semantics', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('navis_tooltip_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () => tester.pump(const Duration(milliseconds: 50)),
    );
    await tester.pumpWidget(
      controller.wrap(
        MaterialApp(
          theme: ThemeData(
            tooltipTheme: const TooltipThemeData(waitDuration: Duration.zero),
          ),
          home: Scaffold(
            body: Center(
              child: Semantics(
                key: ValueKey<String>('desktopPlayerLyricsButton'),
                container: true,
                label: 'Lyrics',
                excludeSemantics: true,
                child: const NavisTooltip(
                  message: 'Lyrics',
                  excludeFromSemantics: true,
                  child: Icon(Icons.lyrics),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final shown = await controller.hoverTooltip(target: 'lyrics');
    expect(shown, isTrue);
    expect(find.byKey(NavisTooltip.defaultBubbleKey), findsOneWidget);
    final dismissed = await controller.hoverTooltip(target: null);
    expect(dismissed, isFalse);
    expect(find.byKey(NavisTooltip.defaultBubbleKey), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('captures a protected deterministic PNG inside artifact root', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 240)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync(
      'navis_presentation_test_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    var waitedForFrame = false;
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () async {
        waitedForFrame = true;
      },
    );

    await tester.pumpWidget(
      controller.wrap(const MaterialApp(home: ColoredBox(color: Colors.blue))),
    );

    expect(controller.status.screenshotReady, isTrue);
    expect(controller.appReady, isFalse);
    expect(controller.status.logicalWidth, 320);
    expect(controller.status.logicalHeight, 240);
    controller.markAppReady();
    expect(controller.appReady, isTrue);
    final capture = (await tester.runAsync<DiagnosticsScreenshot>(
      () => controller.capture(label: 'blue-screen'),
    ))!;
    final file = File(p.join(root.path, capture.artifact));
    final bytes = file.readAsBytesSync();

    expect(capture.artifact, startsWith('screenshots/'));
    expect(waitedForFrame, isTrue);
    expect(p.isWithin(root.path, file.path), isTrue);
    expect(capture.pixelRatio, 1);
    expect(capture.pixelWidth, 320);
    expect(capture.pixelHeight, 240);
    expect(capture.byteCount, bytes.length);
    expect(capture.sha256Digest, hasLength(64));
    expect(
      bytes.take(8),
      orderedEquals(<int>[137, 80, 78, 71, 13, 10, 26, 10]),
    );
    if (!Platform.isWindows) {
      expect(file.statSync().mode & 0x1ff, 0x180);
      expect(
        Directory(p.join(root.path, 'screenshots')).statSync().mode & 0x1ff,
        0x1c0,
      );
    }
  });

  testWidgets('rejects unsafe labels and unavailable render surfaces', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync(
      'navis_presentation_test_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () async {},
    );

    await expectLater(
      controller.capture(label: '../escape'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      controller.capture(label: 'unavailable'),
      throwsA(isA<DiagnosticsPresentationUnavailable>()),
    );
  });
}
