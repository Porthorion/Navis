import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:window_manager/window_manager.dart';

class _FakeWindowManagerAdapter implements WindowManagerAdapter {
  Rect bounds;
  bool maximized;
  Size minimumSize = Size.zero;
  Size maximumSize = const Size(-1, -1);
  double aspectRatio = 0;
  bool resizable = true;
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
        'navis-focus-window-test',
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
      'entering focus mode snapshots normal bounds and persists mode',
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
        await controller.setFocusPlayerMode(true);

        expect(controller.mode, DesktopWindowMode.focusPlayer);
        expect(adapter.minimumSize, DesktopWindowController.focusMinSize);
        expect(adapter.maximumSize, DesktopWindowController.focusMaxSize);
        expect(
          adapter.aspectRatio,
          closeTo(DesktopWindowController.focusAspectRatio, 0.0001),
        );

        final persisted = DesktopWindowStateRecord.fromJson(
          await _readJson(stateFile),
        );
        expect(persisted.activeMode, DesktopWindowMode.focusPlayer);
        expect(persisted.normalBounds?.bounds.size, const Size(1366, 900));

        final settings = await repository.getSettings();
        expect(settings.desktopFocusPlayerModeEnabled, isTrue);
      },
    );

    test('exiting focus mode restores maximized normal state', () async {
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
      await controller.setFocusPlayerMode(true);

      adapter.bounds = const Rect.fromLTWH(80, 90, 920, 412);
      await controller.setFocusPlayerMode(false);

      expect(controller.mode, DesktopWindowMode.normal);
      expect(adapter.maximized, isTrue);
      expect(adapter.minimumSize, DesktopWindowController.normalMinSize);
      expect(adapter.maximumSize, const Size(-1, -1));
      expect(adapter.aspectRatio, 0);

      final settings = await repository.getSettings();
      expect(settings.desktopFocusPlayerModeEnabled, isFalse);
    });

    test('focus bounds persist separately from normal bounds', () async {
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
      await controller.setFocusPlayerMode(true);
      adapter.bounds = const Rect.fromLTWH(100, 120, 1000, 448);
      controller.onWindowResized();
      await Future<void>.delayed(const Duration(milliseconds: 520));

      final persisted = DesktopWindowStateRecord.fromJson(
        await _readJson(stateFile),
      );
      expect(persisted.normalBounds?.bounds.size, const Size(1280, 820));
      expect(persisted.focusBounds, isNotNull);
      expect(persisted.focusBounds!.bounds.width, closeTo(1000, 0.2));
      expect(persisted.focusBounds!.bounds.height, closeTo(448, 0.2));
    });

    test('startup focus mode clamps invalid persisted focus bounds', () async {
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

      expect(controller.mode, DesktopWindowMode.focusPlayer);
      expect(adapter.bounds.width, lessThanOrEqualTo(1040));
      expect(adapter.bounds.height, lessThanOrEqualTo(466));
      expect(adapter.bounds.width, greaterThanOrEqualTo(840));
      expect(adapter.bounds.height, greaterThanOrEqualTo(376));
    });
  });
}

Future<Object?> _readJson(File file) async {
  return file.existsSync() ? file.readAsString().then(jsonDecode) : null;
}
