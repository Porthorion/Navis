import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

class _FakeWindowManagerAdapter implements WindowManagerAdapter {
  Rect bounds;
  bool maximized;
  Size minimumSize = Size.zero;
  Size maximumSize = const Size(-1, -1);
  double aspectRatio = 0;
  bool resizable = true;
  bool alwaysOnTop = false;
  WindowListener? listener;

  _FakeWindowManagerAdapter({
    required this.bounds,
    this.maximized = false,
  });

  @override
  void addListener(WindowListener listener) {
    this.listener = listener;
  }

  @override
  Future<void> center() async {}

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<Rect> getBounds() async => bounds;

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<void> maximize() async {
    maximized = true;
  }

  @override
  Future<void> focus() async {}

  @override
  Future<void> setAspectRatio(double aspectRatio) async {
    this.aspectRatio = aspectRatio;
  }

  @override
  Future<void> setAlwaysOnTop(bool alwaysOnTop) async {
    this.alwaysOnTop = alwaysOnTop;
  }

  @override
  Future<void> setBounds(Rect bounds) async {
    this.bounds = bounds;
  }

  @override
  Future<void> setMaximumSize(Size size) async {
    maximumSize = size;
  }

  @override
  Future<void> setMinimumSize(Size size) async {
    minimumSize = size;
  }

  @override
  Future<void> setResizable(bool resizable) async {
    this.resizable = resizable;
  }

  @override
  Future<void> show() async {}

  @override
  Future<void> unmaximize() async {
    maximized = false;
  }

  @override
  Future<void> waitUntilReadyToShow(
    WindowOptions options,
    Future<void> Function() callback,
  ) async {
    await callback();
  }

  @override
  void removeListener(WindowListener listener) {
    if (this.listener == listener) {
      this.listener = null;
    }
  }
}

class _FakeScreenRetrieverAdapter implements ScreenRetrieverAdapter {
  _FakeScreenRetrieverAdapter(this.displays);

  List<Display> displays;
  ScreenListener? listener;

  @override
  void addListener(ScreenListener listener) {
    this.listener = listener;
  }

  @override
  Future<List<Display>> getAllDisplays() async => displays;

  @override
  void removeListener(ScreenListener listener) {
    if (this.listener == listener) this.listener = null;
  }

  void emit(String eventName) => listener?.onScreenEvent(eventName);
}

void main() {
  group('DesktopWindowController', () {
    late NavisDatabase database;
    late SettingsRepository repository;
    late Directory tempDir;
    late File stateFile;

    setUp(() async {
      database = NavisDatabase(NativeDatabase.memory());
      repository = SettingsRepository(database.appSettingsDao);
      tempDir = await Directory.systemTemp.createTemp(
        'navis-mini-window-test',
      );
      stateFile = File('${tempDir.path}/window_state.json');
    });

    tearDown(() async {
      await database.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'entering Mini Player snapshots Desktop bounds and persists mode',
      () async {
        final adapter = _FakeWindowManagerAdapter(
          bounds: const Rect.fromLTWH(40, 50, 1366, 900),
        );
        final controller = DesktopWindowController(
          desktopRuntime: true,
          stateFile: stateFile,
          settingsRepository: repository,
          adapter: adapter,
        );

        await controller.initialize();
        adapter.bounds = const Rect.fromLTWH(40, 50, 1366, 900);
        await controller.setMiniPlayerMode(true);

        expect(controller.mode, DesktopWindowMode.miniPlayer);
        expect(adapter.minimumSize, DesktopWindowController.miniMinSize);
        expect(adapter.maximumSize, const Size(-1, -1));
        expect(adapter.aspectRatio, 0);
        expect(
          adapter.bounds.size,
          DesktopWindowController.miniDefaultSize,
        );

        final persisted = DesktopWindowStateRecord.fromJson(
          await _readJson(stateFile),
        );
        expect(persisted.activeMode, DesktopWindowMode.miniPlayer);
        expect(persisted.normalBounds?.bounds.size, const Size(1366, 900));

        expect(persisted.version, DesktopWindowStateRecord.currentVersion);
      },
    );

    test('exiting Mini Player restores maximized Desktop state', () async {
      final adapter = _FakeWindowManagerAdapter(
        bounds: const Rect.fromLTWH(40, 50, 1366, 900),
        maximized: true,
      );
      final controller = DesktopWindowController(
        desktopRuntime: true,
        stateFile: stateFile,
        settingsRepository: repository,
        adapter: adapter,
      );

      await controller.initialize();
      adapter.bounds = const Rect.fromLTWH(20, 20, 1280, 820);
      await controller.setMiniPlayerMode(true);

      adapter.bounds = const Rect.fromLTWH(80, 90, 920, 412);
      await controller.setMiniPlayerMode(false);

      expect(controller.mode, DesktopWindowMode.desktop);
      expect(adapter.maximized, isTrue);
      expect(adapter.minimumSize, DesktopWindowController.normalMinSize);
      expect(adapter.maximumSize, const Size(-1, -1));
      expect(adapter.aspectRatio, 0);

      expect(adapter.alwaysOnTop, isFalse);
    });

    test('Mini Player persists position with canonical default size', () async {
      final adapter = _FakeWindowManagerAdapter(
        bounds: const Rect.fromLTWH(20, 20, 1280, 820),
      );
      final controller = DesktopWindowController(
        desktopRuntime: true,
        stateFile: stateFile,
        settingsRepository: repository,
        adapter: adapter,
      );

      await controller.initialize();
      adapter.bounds = const Rect.fromLTWH(20, 20, 1280, 820);
      await controller.setMiniPlayerMode(true);
      adapter.bounds = const Rect.fromLTWH(100, 120, 700, 400);
      controller.onWindowResized();
      await Future<void>.delayed(const Duration(milliseconds: 520));

      final persisted = DesktopWindowStateRecord.fromJson(
        await _readJson(stateFile),
      );
      expect(persisted.normalBounds?.bounds.size, const Size(1280, 820));
      expect(persisted.miniBounds, isNotNull);
      expect(persisted.miniBounds!.bounds.topLeft, const Offset(100, 120));
      expect(
        persisted.miniBounds!.bounds.size,
        DesktopWindowController.miniDefaultSize,
      );
    });

    test('startup imports legacy Focus Player state as Mini Player', () async {
      await repository.saveSettings(
        const AppSettingsModel.defaults().copyWith(
          desktopFocusPlayerModeEnabled: true,
        ),
      );
      await stateFile.writeAsString(
        '{"version":2,"activeMode":"focusPlayer","focusBounds":{"x":0,"y":0,"width":1400,"height":900}}',
      );

      final adapter = _FakeWindowManagerAdapter(
        bounds: const Rect.fromLTWH(0, 0, 1200, 800),
      );
      final controller = DesktopWindowController(
        desktopRuntime: true,
        stateFile: stateFile,
        settingsRepository: repository,
        adapter: adapter,
      );

      await controller.initialize();

      expect(controller.mode, DesktopWindowMode.miniPlayer);
      expect(
        adapter.bounds.size,
        DesktopWindowController.miniDefaultSize,
      );
    });

    test('resize crossing produces one settled transition request', () async {
      final adapter = _FakeWindowManagerAdapter(
        bounds: const Rect.fromLTWH(0, 0, 1200, 760),
      );
      final controller = DesktopWindowController(
        desktopRuntime: true,
        stateFile: stateFile,
        settingsRepository: repository,
        adapter: adapter,
      );
      await controller.initialize();

      controller.updateViewportSize(const Size(799, 599));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controller.transitionRequest, isNull);
      controller.updateViewportSize(const Size(790, 590));
      await Future<void>.delayed(const Duration(milliseconds: 430));

      expect(
        controller.transitionRequest?.direction,
        DesktopWindowTransitionDirection.enterMiniPlayer,
      );
      await controller.resolveTransition(switchMode: true);
      expect(controller.mode, DesktopWindowMode.miniPlayer);
      expect(controller.transitionRequest, isNull);
    });

    test('always-on-top applies only while Mini Player is active', () async {
      final adapter = _FakeWindowManagerAdapter(
        bounds: const Rect.fromLTWH(0, 0, 1200, 760),
      );
      final controller = DesktopWindowController(
        desktopRuntime: true,
        stateFile: stateFile,
        settingsRepository: repository,
        adapter: adapter,
      );
      await controller.initialize();
      await controller.setMiniAlwaysOnTop(true);
      expect(adapter.alwaysOnTop, isFalse);

      await controller.setMiniPlayerMode(true);
      expect(adapter.alwaysOnTop, isTrue);
      await controller.setMiniPlayerMode(false);
      expect(adapter.alwaysOnTop, isFalse);
    });

    test(
      'unavailable always-on-top never enables a misleading Mini Player pin',
      () async {
        final adapter = _FakeWindowManagerAdapter(
          bounds: const Rect.fromLTWH(0, 0, 1200, 760),
        );
        final controller = DesktopWindowController(
          desktopRuntime: true,
          stateFile: stateFile,
          settingsRepository: repository,
          adapter: adapter,
          alwaysOnTopSupported: false,
        );
        await controller.initialize();
        await controller.setMiniPlayerMode(true);
        await controller.setMiniAlwaysOnTop(true);

        expect(controller.supportsMiniAlwaysOnTop, isFalse);
        expect(controller.miniAlwaysOnTop, isFalse);
        expect(adapter.alwaysOnTop, isFalse);
      },
    );

    test('a small display starts and remains in Mini Player', () async {
      final adapter = _FakeWindowManagerAdapter(
        bounds: const Rect.fromLTWH(0, 0, 700, 500),
      );
      final screens = _FakeScreenRetrieverAdapter(const <Display>[
        Display(
          id: 'small',
          size: Size(700, 500),
          visiblePosition: Offset.zero,
          visibleSize: Size(700, 500),
        ),
      ]);
      final controller = DesktopWindowController(
        desktopRuntime: true,
        stateFile: stateFile,
        settingsRepository: repository,
        adapter: adapter,
        screenAdapter: screens,
      );

      await controller.initialize();
      expect(controller.mode, DesktopWindowMode.miniPlayer);
      expect(controller.desktopViewAvailable, isFalse);
      await controller.setMiniPlayerMode(false);
      expect(controller.mode, DesktopWindowMode.miniPlayer);
    });

    test(
      'off-screen bounds follow the display with greatest intersection',
      () async {
        await stateFile.writeAsString(
          jsonEncode(
            DesktopWindowStateRecord(
              version: DesktopWindowStateRecord.currentVersion,
              activeMode: DesktopWindowMode.desktop,
              normalBounds: const DesktopWindowSnapshot(
                Rect.fromLTWH(2100, 100, 1000, 700),
              ),
            ).toJson(),
          ),
        );
        final adapter = _FakeWindowManagerAdapter(
          bounds: const Rect.fromLTWH(0, 0, 1200, 760),
        );
        final screens = _FakeScreenRetrieverAdapter(const <Display>[
          Display(
            id: 'primary',
            size: Size(1920, 1080),
            visiblePosition: Offset.zero,
            visibleSize: Size(1920, 1040),
          ),
          Display(
            id: 'secondary',
            size: Size(1600, 900),
            visiblePosition: Offset(1920, 0),
            visibleSize: Size(1600, 860),
          ),
        ]);
        final controller = DesktopWindowController(
          desktopRuntime: true,
          stateFile: stateFile,
          settingsRepository: repository,
          adapter: adapter,
          screenAdapter: screens,
        );

        await controller.initialize();
        expect(adapter.bounds.left, greaterThanOrEqualTo(1920));
        expect(adapter.bounds.right, lessThanOrEqualTo(3520));
        expect(adapter.bounds.top, greaterThanOrEqualTo(0));
        expect(adapter.bounds.bottom, lessThanOrEqualTo(860));
      },
    );

    test('display removal brings the current window back on screen', () async {
      final adapter = _FakeWindowManagerAdapter(
        bounds: const Rect.fromLTWH(2200, 100, 1000, 700),
      );
      final screens = _FakeScreenRetrieverAdapter(<Display>[
        const Display(
          id: 'primary',
          size: Size(1920, 1080),
          visiblePosition: Offset.zero,
          visibleSize: Size(1920, 1040),
        ),
        const Display(
          id: 'secondary',
          size: Size(1600, 900),
          visiblePosition: Offset(1920, 0),
          visibleSize: Size(1600, 860),
        ),
      ]);
      final controller = DesktopWindowController(
        desktopRuntime: true,
        stateFile: stateFile,
        settingsRepository: repository,
        adapter: adapter,
        screenAdapter: screens,
      );
      await controller.initialize();
      adapter.bounds = const Rect.fromLTWH(2200, 100, 1000, 700);

      screens.displays = <Display>[screens.displays.first];
      screens.emit('display-removed');
      await Future<void>.delayed(Duration.zero);

      expect(adapter.bounds.left, greaterThanOrEqualTo(0));
      expect(adapter.bounds.right, lessThanOrEqualTo(1920));
      expect(adapter.bounds.bottom, lessThanOrEqualTo(1040));
    });

    test('keeping Mini Player restores its canonical default bounds', () async {
      final adapter = _FakeWindowManagerAdapter(
        bounds: const Rect.fromLTWH(20, 20, 1200, 760),
      );
      final controller = DesktopWindowController(
        desktopRuntime: true,
        stateFile: stateFile,
        settingsRepository: repository,
        adapter: adapter,
      );
      await controller.initialize();
      await controller.setMiniPlayerMode(true);
      final compactBounds = adapter.bounds;
      adapter.bounds = const Rect.fromLTWH(20, 20, 900, 700);
      controller.updateViewportSize(adapter.bounds.size);
      await Future<void>.delayed(const Duration(milliseconds: 430));

      await controller.resolveTransition(switchMode: false);

      expect(controller.mode, DesktopWindowMode.miniPlayer);
      expect(adapter.bounds.size, compactBounds.size);
      controller.updateViewportSize(adapter.bounds.size);
      expect(controller.transitionRequest, isNull);
    });

    test(
      'mode cycles preserve valid Desktop bounds and always re-enter canonical Mini Player',
      () async {
        final adapter = _FakeWindowManagerAdapter(
          bounds: const Rect.fromLTWH(30, 40, 1200, 760),
        );
        final controller = DesktopWindowController(
          desktopRuntime: true,
          stateFile: stateFile,
          settingsRepository: repository,
          adapter: adapter,
        );
        await controller.initialize();
        adapter.bounds = const Rect.fromLTWH(30, 40, 1366, 820);
        controller.onWindowResized();
        await Future<void>.delayed(const Duration(milliseconds: 520));

        adapter.bounds = const Rect.fromLTWH(30, 40, 799, 599);
        controller.updateViewportSize(adapter.bounds.size);
        await Future<void>.delayed(const Duration(milliseconds: 430));
        await controller.resolveTransition(switchMode: true);

        expect(controller.mode, DesktopWindowMode.miniPlayer);
        expect(
          adapter.bounds.size,
          DesktopWindowController.miniDefaultSize,
        );

        adapter.bounds = const Rect.fromLTWH(30, 40, 900, 700);
        controller.updateViewportSize(adapter.bounds.size);
        await Future<void>.delayed(const Duration(milliseconds: 430));
        await controller.resolveTransition(switchMode: true);

        expect(controller.mode, DesktopWindowMode.desktop);
        expect(adapter.bounds.size, const Size(1366, 820));

        await controller.setMiniPlayerMode(true);
        expect(controller.mode, DesktopWindowMode.miniPlayer);
        expect(
          adapter.bounds.size,
          DesktopWindowController.miniDefaultSize,
        );
        controller.updateViewportSize(adapter.bounds.size);
        expect(controller.transitionRequest, isNull);
      },
    );

    test(
      'undersized Mini Player automatically restores valid bounds',
      () async {
        final adapter = _FakeWindowManagerAdapter(
          bounds: const Rect.fromLTWH(20, 20, 1200, 760),
        );
        final controller = DesktopWindowController(
          desktopRuntime: true,
          stateFile: stateFile,
          settingsRepository: repository,
          adapter: adapter,
        );
        await controller.initialize();
        await controller.setMiniPlayerMode(true);
        final validBounds = adapter.bounds;

        adapter.bounds = const Rect.fromLTWH(20, 20, 392, 184);
        controller.updateViewportSize(adapter.bounds.size);
        await Future<void>.delayed(const Duration(milliseconds: 430));

        expect(controller.mode, DesktopWindowMode.miniPlayer);
        expect(controller.transitionRequest, isNull);
        expect(adapter.bounds, validBounds);
      },
    );

    test('diagnostic resize deterministically exits maximized state', () async {
      final adapter = _FakeWindowManagerAdapter(
        bounds: const Rect.fromLTWH(0, 0, 1440, 900),
      )..maximized = true;
      final controller = DesktopWindowController(
        desktopRuntime: true,
        stateFile: stateFile,
        settingsRepository: repository,
        adapter: adapter,
      );

      await controller.setBoundsForDiagnostics(
        const Rect.fromLTWH(45, 45, 800, 600),
      );

      expect(adapter.maximized, isFalse);
      expect(adapter.bounds, const Rect.fromLTWH(45, 45, 800, 600));
    });

    test(
      'diagnostic resize gate restores the last valid Desktop bounds',
      () async {
        final adapter = _FakeWindowManagerAdapter(
          bounds: const Rect.fromLTWH(45, 45, 1200, 760),
        );
        final controller = DesktopWindowController(
          desktopRuntime: true,
          stateFile: stateFile,
          settingsRepository: repository,
          adapter: adapter,
        );
        await controller.initialize();
        await controller.setBoundsForDiagnostics(
          const Rect.fromLTWH(45, 45, 800, 600),
        );
        await controller.setBoundsForDiagnostics(
          const Rect.fromLTWH(45, 45, 799, 599),
        );
        controller.updateViewportSize(const Size(799, 599));
        await Future<void>.delayed(const Duration(milliseconds: 430));

        await controller.resolveTransition(switchMode: false);

        expect(adapter.bounds, const Rect.fromLTWH(45, 45, 800, 600));
      },
    );
  });
}

Future<Object?> _readJson(File file) async {
  return file.existsSync() ? file.readAsString().then(jsonDecode) : null;
}
