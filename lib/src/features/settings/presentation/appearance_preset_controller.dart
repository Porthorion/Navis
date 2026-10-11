import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common/preset_names.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:uuid/uuid.dart';

class ColorTuningState {
  const new({required this.tuning});
  final ColorTuning tuning;
}

/// Shares the existing settings stream and preview; serializes targeted writes.
class ColorTuningController extends Notifier<ColorTuningState> {
  final _writes = _WriteLane();

  @override
  ColorTuningState build() {
    ref.listen(effectiveColorTuningProvider, (_, _) => _refresh());
    ref.listen(colorTuningProvider, (_, saved) {
      if (ref.read(colorTuningPreviewProvider) == saved) {
        clearPreview();
      }
    });
    return ColorTuningState(tuning: ref.read(effectiveColorTuningProvider));
  }

  void _refresh() =>
      state = ColorTuningState(tuning: ref.read(effectiveColorTuningProvider));

  void preview(ColorTuning tuning) =>
      ref.read(colorTuningPreviewProvider.notifier).preview(tuning);
  void clearPreview() => ref.read(colorTuningPreviewProvider.notifier).clear();

  Future<PresetFailure?> commit(ColorTuning tuning) {
    preview(tuning);
    return _writes.run(() async {
      try {
        await ref.read(settingsRepositoryProvider).getSettings();
        await ref
            .read(navisDatabaseProvider)
            .appSettingsDao
            .updateColorTuning(tuning);
        await _observeSettings(ref, (s) => s.colorTuning == tuning);
        if (ref.mounted) {
          state = ColorTuningState(
            tuning: ref.read(colorTuningPreviewProvider) ?? tuning,
          );
          if (ref.read(colorTuningProvider) ==
              ref.read(colorTuningPreviewProvider)) {
            clearPreview();
          }
        }
        return null;
      } on Object {
        if (ref.mounted && ref.read(colorTuningPreviewProvider) == tuning) {
          clearPreview();
        }
        return PresetFailure.persistence;
      }
    });
  }
}

final colorTuningControllerProvider =
    NotifierProvider<ColorTuningController, ColorTuningState>(
      ColorTuningController.new,
    );

class AppearanceLooksState {
  new(AppSettingsModel settings)
    : looks = List.unmodifiable(settings.appearanceLooks),
      selectedLookId = matchingAppearanceLookId(settings);
  final List<AppearanceLook> looks;
  final String? selectedLookId;
}

class AppearanceLooksController extends Notifier<AppearanceLooksState> {
  final _writes = _WriteLane();

  /// The Look selected before the last [apply], so Undo returns to it even
  /// when several Looks hold the same appearance.
  String? _selectionBeforeApply;
  @override
  AppearanceLooksState build() {
    ref.listen(appSettingsProvider, (_, next) {
      state = AppearanceLooksState(
        next.asData?.value ?? const AppSettingsModel.defaults(),
      );
    });
    return AppearanceLooksState(
      ref.read(appSettingsProvider).asData?.value ??
          const AppSettingsModel.defaults(),
    );
  }

  /// Applies a saved Look and returns the appearance to use for Undo.
  ///
  /// Unknown ids and failed applications return null.
  Future<AppearanceSnapshot?> apply(String id) => _writes.run(() async {
    try {
      final settings = await ref.read(settingsRepositoryProvider).getSettings();
      final look = settings.appearanceLooks
          .where((p) => p.id == id)
          .firstOrNull;
      if (look == null) return null;
      _selectionBeforeApply = matchingAppearanceLookId(settings);
      return await _applySnapshot(look.snapshot, select: look.id);
    } on Object {
      return null;
    }
  });

  /// Restores the captured appearance, including automatic nullable settings.
  ///
  /// Returns null on success or [PresetFailure.persistence] on failure.
  Future<PresetFailure?> restore(AppearanceSnapshot previous) =>
      _writes.run(() async {
        try {
          await _applySnapshot(previous, select: _selectionBeforeApply);
          return null;
        } on Object {
          return PresetFailure.persistence;
        }
      });

  Future<AppearanceSnapshot> _applySnapshot(
    AppearanceSnapshot snapshot, {
    String? select,
  }) async {
    final dao = ref.read(navisDatabaseProvider).appSettingsDao;
    final repository = ref.read(settingsRepositoryProvider);
    late AppSettingsModel applied;
    final previous = await dao.transaction(() async {
      final before = AppearanceSnapshot.capture(await repository.getSettings());
      await dao.applyAppearanceSnapshot(snapshot);
      applied = await repository.getSettings();
      final selected = matchingAppearanceLookId(applied, prefer: select);
      await dao.updateAppearanceLooks(selectedLookId: selected);
      applied = applied.copyWith(selectedAppearanceLookId: selected);
      return before;
    });
    if (ref.mounted) ref.read(colorTuningPreviewProvider.notifier).clear();
    await _observeSettings(
      ref,
      (s) =>
          AppearanceSnapshot.capture(s) == AppearanceSnapshot.capture(applied),
    );
    if (ref.mounted) state = AppearanceLooksState(applied);
    return previous;
  }

  Future<PresetResult<AppearanceLook>> saveAsNew(String name) =>
      _save(name: name);
  Future<PresetFailure?> update(String id) async =>
      (await _save(id: id)).failure;
  Future<PresetFailure?> rename(String id, String name) async =>
      (await _save(id: id, name: name, renameOnly: true)).failure;

  Future<PresetResult<AppearanceLook>> _save({
    String? id,
    String? name,
    bool renameOnly = false,
  }) => _writes.run(() async {
    try {
      final settings = await ref.read(settingsRepositoryProvider).getSettings();
      final old = settings.appearanceLooks.where((p) => p.id == id).firstOrNull;
      if (id != null && old == null) {
        return const PresetResult.failure(PresetFailure.notFound);
      }
      final label = name ?? old!.name;
      final failure = validatePresetName(
        label,
        presets: settings.appearanceLooks.map((p) => (id: p.id, name: p.name)),
        excludingId: id,
        reservedNames: const {'default'},
      );
      if (failure != null) {
        return PresetResult.failure(failure);
      }
      final look = AppearanceLook(
        id: id ?? const Uuid().v4(),
        name: label.trim(),
        snapshot: renameOnly
            ? old!.snapshot
            : AppearanceSnapshot.capture(settings),
      );
      final looks = [...settings.appearanceLooks];
      final index = looks.indexWhere((p) => p.id == id);
      if (index < 0) {
        looks.add(look);
      } else {
        looks[index] = look;
      }
      // Saving or updating selects that Look; a rename keeps the selection.
      await _write(
        settings.copyWith(appearanceLooks: looks),
        prefer: renameOnly ? null : look.id,
      );
      return PresetResult.success(look);
    } on Object {
      return const PresetResult.failure(PresetFailure.persistence);
    }
  });

  Future<PresetFailure?> delete(String id) => _writes.run(() async {
    try {
      final settings = await ref.read(settingsRepositoryProvider).getSettings();
      if (!settings.appearanceLooks.any((p) => p.id == id)) {
        return PresetFailure.notFound;
      }
      await _write(
        settings.copyWith(
          appearanceLooks: settings.appearanceLooks
              .where((p) => p.id != id)
              .toList(),
        ),
      );
      return null;
    } on Object {
      return PresetFailure.persistence;
    }
  });

  Future<void> _write(AppSettingsModel settings, {String? prefer}) async {
    await ref
        .read(navisDatabaseProvider)
        .appSettingsDao
        .updateAppearanceLooks(
          selectedLookId: matchingAppearanceLookId(settings, prefer: prefer),
          looksJson: jsonEncode(
            settings.appearanceLooks.map((p) => p.toJson()).toList(),
          ),
        );
    final observed = await _observeSettings(
      ref,
      (s) =>
          jsonEncode(s.appearanceLooks.map((p) => p.toJson()).toList()) ==
          jsonEncode(settings.appearanceLooks.map((p) => p.toJson()).toList()),
    );
    if (ref.mounted) state = AppearanceLooksState(observed);
  }
}

final appearanceLooksControllerProvider =
    NotifierProvider<AppearanceLooksController, AppearanceLooksState>(
      AppearanceLooksController.new,
    );

class _WriteLane {
  Future<void> _tail = Future<void>.value();
  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }
}

/// A temporary subscription to the existing provider also keeps command-only
/// diagnostics callers active while the committed row reaches the UI stream.
Future<AppSettingsModel> _observeSettings(
  Ref ref,
  bool Function(AppSettingsModel) matches,
) async {
  final completion = Completer<AppSettingsModel>();
  final subscription = ref.container.listen(appSettingsProvider, (_, next) {
    if (completion.isCompleted) return;
    if (next case AsyncData(:final value) when matches(value)) {
      completion.complete(value);
    } else if (next case AsyncError(:final error, :final stackTrace)) {
      completion.completeError(error, stackTrace);
    }
  }, fireImmediately: true);
  final removeDispose = ref.onDispose(() {
    subscription.close();
    if (!completion.isCompleted) {
      completion.completeError(StateError('Appearance controller disposed'));
    }
  });
  try {
    return await completion.future;
  } finally {
    subscription.close();
    removeDispose();
  }
}
