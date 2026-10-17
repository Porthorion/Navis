import 'dart:async';
import 'dart:io';

import 'package:navis/src/common/preset_names.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:uuid/uuid.dart';

final playbackAdjustmentCapabilitiesProvider =
    Provider<PlaybackAdjustmentCapabilities>((ref) {
      final handler = ref.watch(audioHandlerProvider);
      if (handler != null) return handler.playbackAdjustmentCapabilities;
      if (JustAudioMediaKit.isRegistered && JustAudioMediaKit.pitch) {
        return PlaybackAdjustmentCapabilities.mediaKit;
      }
      if (Platform.isAndroid) return PlaybackAdjustmentCapabilities.android;
      return const PlaybackAdjustmentCapabilities();
    });

enum PlaybackAdjustmentFailure {
  unsupported,
  lockUnsupported,
  application,
  persistence,
  name,
  presetMissing,
}

/// Values equal up to floating-point noise (the tolerance [isHundredth]
/// uses), so 1.4500000000000002 still counts as a preset's 1.45.
bool _sameValues(PlaybackAdjustments a, PlaybackAdjustments b) =>
    a.lockPitchToSpeed == b.lockPitchToSpeed &&
    (a.speed - b.speed).abs() < 1e-9 &&
    (a.pitchSemitones - b.pitchSemitones).abs() < 1e-9;

class PlaybackAdjustmentState {
  new({
    this.values = const PlaybackAdjustments(),
    List<PlaybackPreset> presets = const [],
    this.selectedPresetId,
    this.originPresetId,
    this.pending = false,
    this.failure,
  }) : presets = List.unmodifiable(presets);

  final PlaybackAdjustments values;
  final List<PlaybackPreset> presets;
  final String? selectedPresetId;
  final String? originPresetId;
  final bool pending;
  final PlaybackAdjustmentFailure? failure;

  PlaybackAdjustmentState copyWith({
    PlaybackAdjustments? values,
    List<PlaybackPreset>? presets,
    String? selectedPresetId,
    String? originPresetId,
    bool? pending,
    PlaybackAdjustmentFailure? failure,
  }) => PlaybackAdjustmentState(
    values: values ?? this.values,
    presets: presets ?? this.presets,
    selectedPresetId: selectedPresetId,
    originPresetId: originPresetId,
    pending: pending ?? this.pending,
    failure: failure,
  );
}

/// Owns adjustments and writes across panel and navigation lifetimes.
class PlaybackAdjustmentController
    extends AsyncNotifier<PlaybackAdjustmentState> {
  Timer? _saveTimer;
  Future<void> _applyLane = Future<void>.value();
  Future<void> _saveLane = Future<void>.value();
  int _generation = 0;
  int _saveRevision = 0;
  bool _presetsDirty = false;
  PlaybackAdjustmentState? _confirmed;
  StreamSubscription<PlaybackAdjustments>? _engineSubscription;
  int _engineEpoch = 0;
  PlaybackAdjustments? _lastEngineEvent;

  @override
  Future<PlaybackAdjustmentState> build() async {
    ref.onDispose(() {
      _saveTimer?.cancel();
      unawaited(_engineSubscription?.cancel());
      _engineEpoch++;
    });
    ref.listen(audioHandlerProvider, (previous, next) {
      if (!identical(previous, next)) {
        _engineEpoch++;
        _lastEngineEvent = null;
        unawaited(_engineSubscription?.cancel());
        _engineSubscription = null;
        if (next != null) unawaited(_hydrateEngine());
      }
    });
    ref.listen(appSettingsProvider, (_, next) {
      final settings = next.asData?.value;
      final current = state.asData?.value;
      if (settings == null || current == null || _presetsDirty) return;
      final ids = settings.playbackPresets.map((p) => p.id).toSet();
      final refreshed = current.copyWith(
        presets: settings.playbackPresets,
        selectedPresetId: ids.contains(current.selectedPresetId)
            ? current.selectedPresetId
            : settings.selectedPlaybackPresetId == PlaybackPreset.noneId &&
                  current.values.isNone
            ? PlaybackPreset.noneId
            : null,
        originPresetId: ids.contains(current.originPresetId)
            ? current.originPresetId
            : null,
        failure: current.failure,
      );
      state = AsyncData(refreshed);
      if (_confirmed != null) {
        _confirmed = _confirmed!.copyWith(
          presets: refreshed.presets,
          selectedPresetId: refreshed.selectedPresetId,
          originPresetId: refreshed.originPresetId,
        );
      }
    });
    final settings =
        ref.read(appSettingsProvider).asData?.value ??
        await ref.read(settingsRepositoryProvider).getSettings();
    var values = PlaybackAdjustments(
      speed: settings.playbackSpeed,
      pitchSemitones: settings.playbackPitchSemitones,
      lockPitchToSpeed: settings.lockPitchToSpeed,
    );
    if (!values.isValid) values = const PlaybackAdjustments();
    final capabilities = ref.read(playbackAdjustmentCapabilitiesProvider);
    final unsupported = !capabilities.supports(values);
    if (!capabilities.pitchSupported ||
        (unsupported && values.lockPitchToSpeed)) {
      values = values.copyWith(pitchSemitones: 0, lockPitchToSpeed: false);
    }
    if (!capabilities.supports(values)) values = const PlaybackAdjustments();
    var applicationFailed = false;
    final handler = ref.read(audioHandlerProvider);
    if (handler != null && handler.playbackAdjustments != values) {
      try {
        await handler.setPlaybackAdjustments(values);
      } on Object {
        values = handler.playbackAdjustments;
        applicationFailed = true;
      }
    }
    final selected = unsupported || applicationFailed
        ? null
        : settings.selectedPlaybackPresetId;
    final matching = settings.playbackPresets.where(
      (p) => p.id == selected && _sameValues(p.values, values),
    );
    final resolved = matching.isNotEmpty
        ? selected
        : values.isNone
        ? PlaybackPreset.noneId
        : null;
    final loaded = PlaybackAdjustmentState(
      values: values,
      presets: settings.playbackPresets,
      failure: applicationFailed
          ? PlaybackAdjustmentFailure.application
          : unsupported
          ? PlaybackAdjustmentFailure.unsupported
          : null,
      selectedPresetId: resolved,
      // The stored id is also the origin while the values are Custom, as for
      // Looks, so "<name>*" and Discard survive a restart.
      originPresetId:
          resolved == PlaybackPreset.noneId ||
              !settings.playbackPresets.any((p) => p.id == selected)
          ? null
          : selected,
    );
    _confirmed = loaded;
    if (handler != null) _watchEngine(handler);
    return loaded;
  }

  void _watchEngine(NavisPlaybackHandler handler) {
    unawaited(_engineSubscription?.cancel());
    final epoch = ++_engineEpoch;
    _lastEngineEvent = null;
    _engineSubscription = handler.playbackAdjustmentsStream.listen((values) {
      if (!ref.mounted || epoch != _engineEpoch) return;
      _lastEngineEvent = values;
      if (state.asData?.value.pending == false) _acceptEngineValue(values);
    });
  }

  void _acceptEngineValue(PlaybackAdjustments values) {
    final current = state.asData?.value;
    if (current == null || current.values == values || current.pending) return;
    _generation++;
    _confirmed = current.copyWith(
      values: values,
      selectedPresetId: values.isNone ? PlaybackPreset.noneId : null,
      originPresetId: current.originPresetId,
      pending: false,
    );
    state = AsyncData(_confirmed!);
    _saveRevision++;
    _scheduleSave();
  }

  Future<void> _hydrateEngine() async {
    try {
      await future;
    } on Object {
      return;
    }
    await _applyLane;
    if (!ref.mounted) return;
    final current = _current;
    final handler = ref.read(audioHandlerProvider);
    if (handler == null) return;
    if (handler.playbackAdjustments != current.values) {
      await setValues(current.values, presetId: current.selectedPresetId);
    }
    if (ref.mounted) _watchEngine(handler);
  }

  PlaybackAdjustmentState get _current => state.requireValue;

  Future<bool> setValues(PlaybackAdjustments values, {String? presetId}) async {
    await future;
    if (!ref.mounted) return false;
    if (!ref.read(playbackAdjustmentCapabilitiesProvider).supports(values)) {
      _failure(PlaybackAdjustmentFailure.unsupported);
      return false;
    }
    final generation = ++_generation;
    final previous = _current;
    final origin = presetId == null
        ? previous.originPresetId ??
              (previous.selectedPresetId == PlaybackPreset.noneId
                  ? null
                  : previous.selectedPresetId)
        : presetId == PlaybackPreset.noneId
        ? null
        : presetId;
    state = AsyncData(
      previous.copyWith(values: values, originPresetId: origin, pending: true),
    );
    var applied = false;
    final operation = _applyLane.then((_) async {
      if (!ref.mounted || generation != _generation) return;
      try {
        await ref.read(audioHandlerProvider)?.setPlaybackAdjustments(values);
        if (!ref.mounted) return;
        // A newer drag value owns the preview, but this is now the engine's
        // confirmed value and is the rollback target if that newer call fails.
        _confirmed = _current.copyWith(
          values: values,
          selectedPresetId:
              presetId ??
              (values.isNone
                  ? PlaybackPreset.noneId
                  : _current.presets.any(
                      (p) => p.id == origin && _sameValues(p.values, values),
                    )
                  ? origin
                  : null),
          originPresetId: origin,
          pending: false,
        );
        if (generation != _generation) return;
        state = AsyncData(_confirmed!);
        _saveRevision++;
        _scheduleSave();
        applied = true;
      } on Object {
        if (!ref.mounted || generation != _generation) return;
        final confirmed = _confirmed!;
        final actual =
            ref.read(audioHandlerProvider)?.playbackAdjustments ??
            confirmed.values;
        final same = actual == confirmed.values;
        state = AsyncData(
          confirmed.copyWith(
            values: actual,
            selectedPresetId: same
                ? confirmed.selectedPresetId
                : actual.isNone
                ? PlaybackPreset.noneId
                : null,
            originPresetId: same ? confirmed.originPresetId : null,
            failure: PlaybackAdjustmentFailure.application,
            pending: false,
          ),
        );
      }
    });
    _applyLane = operation;
    await operation;
    if (ref.mounted && generation == _generation && _lastEngineEvent != null) {
      _acceptEngineValue(
        ref.read(audioHandlerProvider)?.playbackAdjustments ??
            _lastEngineEvent!,
      );
    }
    return applied;
  }

  Future<bool> setPitchLock({required bool enabled}) async {
    await future;
    final values = _current.values.copyWith(lockPitchToSpeed: enabled);
    if (!ref.read(playbackAdjustmentCapabilitiesProvider).supports(values)) {
      _failure(PlaybackAdjustmentFailure.lockUnsupported);
      return false;
    }
    final result = await setValues(values);
    if (result) await flush();
    return result;
  }

  Future<bool> selectPreset(String id) async {
    await future;
    final preset = id == PlaybackPreset.noneId
        ? PlaybackPreset.none
        : _current.presets.where((p) => p.id == id).firstOrNull;
    if (preset == null) return false;
    final result = await setValues(preset.values, presetId: id);
    if (result) await flush();
    return result;
  }

  Future<bool> savePreset(String name, {String? updateId}) async {
    await flush();
    if (!ref.mounted) return false;
    final current = _current;
    if (current.pending) return false;
    final trimmed = name.trim();
    if (updateId == PlaybackPreset.noneId ||
        validatePresetName(
              trimmed,
              presets: current.presets.map((p) => (id: p.id, name: p.name)),
              excludingId: updateId,
              reservedNames: const {'none', 'normal'},
            ) !=
            null) {
      _failure(PlaybackAdjustmentFailure.name);
      return false;
    }
    if (updateId != null && !current.presets.any((p) => p.id == updateId)) {
      return false;
    }
    final preset = PlaybackPreset(
      id: updateId ?? const Uuid().v4(),
      name: trimmed,
      values: current.values,
    );
    final presets = [...current.presets];
    final index = presets.indexWhere((p) => p.id == preset.id);
    if (index < 0) {
      presets.add(preset);
    } else {
      presets[index] = preset;
    }
    _presetsDirty = true;
    state = AsyncData(
      current.copyWith(
        presets: presets,
        selectedPresetId: preset.id,
        originPresetId: preset.id,
        pending: false,
      ),
    );
    _confirmed = _current;
    _saveRevision++;
    return await _persist();
  }

  Future<bool> renamePreset(String id, String name) async {
    await flush();
    final current = _current;
    if (current.pending) return false;
    final preset = current.presets.where((p) => p.id == id).firstOrNull;
    if (preset == null ||
        validatePresetName(
              name,
              presets: current.presets.map((p) => (id: p.id, name: p.name)),
              excludingId: id,
              reservedNames: const {'none', 'normal'},
            ) !=
            null) {
      _failure(PlaybackAdjustmentFailure.name);
      return false;
    }
    _presetsDirty = true;
    state = AsyncData(
      current.copyWith(
        presets: [
          for (final p in current.presets)
            if (p.id == id)
              PlaybackPreset(id: id, name: name.trim(), values: p.values)
            else
              p,
        ],
        selectedPresetId: current.selectedPresetId,
        originPresetId: current.originPresetId,
      ),
    );
    _confirmed = _current;
    _saveRevision++;
    return await _persist();
  }

  Future<bool> deletePreset(String id) async {
    await flush();
    if (_current.pending ||
        id == PlaybackPreset.noneId ||
        !_current.presets.any((p) => p.id == id)) {
      _failure(PlaybackAdjustmentFailure.presetMissing);
      return false;
    }
    final current = _current;
    _presetsDirty = true;
    state = AsyncData(
      current.copyWith(
        presets: current.presets.where((p) => p.id != id).toList(),
        selectedPresetId: current.selectedPresetId == id
            ? null
            : current.selectedPresetId,
        originPresetId: current.originPresetId == id
            ? null
            : current.originPresetId,
      ),
    );
    _confirmed = _current;
    _saveRevision++;
    return await _persist();
  }

  /// Drains pending saves and keeps the reset in the same persistence lane.
  Future<void> resetPresets(Future<void> Function() clear) async {
    await flush();
    final operation = _saveLane.then((_) async {
      await clear();
      if (!ref.mounted) return;
      _presetsDirty = false;
      _saveRevision++;
      state = AsyncData(_current.copyWith(presets: const []));
      _confirmed = _confirmed?.copyWith(presets: const []);
    });
    _saveLane = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    await operation;
  }

  void _failure(PlaybackAdjustmentFailure failure) {
    final current = _current;
    state = AsyncData(
      current.copyWith(
        selectedPresetId: current.selectedPresetId,
        originPresetId: current.originPresetId,
        failure: failure,
      ),
    );
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_persist()),
    );
  }

  Future<void> flush() async {
    if (!ref.mounted) return;
    try {
      await future;
    } on Object {
      return;
    }
    if (!ref.mounted) return;
    await _applyLane;
    await _persist();
  }

  Future<bool> _persist() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_confirmed == null || !ref.mounted) return false;
    var saved = false;
    final operation = _saveLane.then((_) async {
      if (!ref.mounted) return;
      final snapshot = _confirmed!;
      final revision = _saveRevision;
      final writePresets = _presetsDirty;
      try {
        await ref
            .read(settingsRepositoryProvider)
            .savePlaybackAdjustments(
              values: snapshot.values,
              selectedPresetId:
                  snapshot.selectedPresetId ?? snapshot.originPresetId,
              presets: writePresets ? snapshot.presets : null,
            );
        saved = true;
        if (!ref.mounted || revision != _saveRevision) return;
        if (writePresets) _presetsDirty = false;
        final current = _current;
        if (current.failure == PlaybackAdjustmentFailure.persistence) {
          state = AsyncData(
            current.copyWith(
              selectedPresetId: current.selectedPresetId,
              originPresetId: current.originPresetId,
            ),
          );
        }
      } on Object {
        if (ref.mounted && revision == _saveRevision) {
          _failure(PlaybackAdjustmentFailure.persistence);
        }
      }
    });
    _saveLane = operation;
    await operation;
    return saved;
  }
}

final playbackAdjustmentsProvider =
    AsyncNotifierProvider<
      PlaybackAdjustmentController,
      PlaybackAdjustmentState
    >(PlaybackAdjustmentController.new);
