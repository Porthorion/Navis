import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/data/autoeq_catalogue.dart';
import 'package:navis/src/features/equalizer/data/eq_platform_support.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:uuid/uuid.dart';

final autoEqCatalogueProvider = Provider<AutoEqCatalogue>(
  (ref) => AutoEqCatalogue(),
);

final eqCapabilitiesProvider = Provider<EqCapabilities>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  return handler?.equalizerCapabilities ??
      (navisEqualizerSupported()
          ? EqCapabilities.available
          : EqCapabilities.unavailable);
});

const _keep = Object();

class EqState {
  EqState({
    required this.configuration,
    required List<EqPreset> presets,
    this.selectedPresetId,
    this.originPresetId,
    Map<String, EqWorkspace> workspaces = const {},
    this.draftPersisted = true,
    this.application,
    this.pending = false,
    this.failure,
    this.legacyResetNotice = false,
    this.recoveryMessage,
  }) : presets = List.unmodifiable(presets),
       workspaces = Map.unmodifiable(workspaces);

  final EqConfiguration configuration;
  final List<EqPreset> presets;
  final String? selectedPresetId;
  final String? originPresetId;
  final Map<String, EqWorkspace> workspaces;
  final bool draftPersisted;
  String get workspaceId => selectedPresetId ?? eqCustomWorkspace;
  EqWorkspace get workspace =>
      workspaces[workspaceId] ?? EqWorkspace.fromConfiguration(configuration);
  bool get dirty =>
      selected == null || !sameEqCurve(configuration, selected!.configuration);
  bool hasDraft(String id) => id == eqCustomWorkspace
      ? workspaces.containsKey(id)
      : _find(id) != null &&
            (workspaces[id]?.differsFrom(_find(id)!.configuration) ?? false);
  String displayName(String custom) =>
      "${selected?.name ?? custom}${hasDraft(workspaceId) ? '*' : ''}";
  final EqApplicationState? application;
  final bool pending;
  final String? failure;
  final bool legacyResetNotice;
  final String? recoveryMessage;

  List<EqPreset> get allPresets => [...EqPreset.builtIns, ...presets];
  EqPreset? get selected => _find(selectedPresetId);
  EqPreset? get origin => _find(originPresetId);
  EqPreset? _find(String? id) {
    for (final preset in allPresets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  EqState copyWith({
    EqConfiguration? configuration,
    List<EqPreset>? presets,
    Object? selectedPresetId = _keep,
    Object? originPresetId = _keep,
    Map<String, EqWorkspace>? workspaces,
    bool? draftPersisted,
    EqApplicationState? application,
    bool? pending,
    String? failure,
    bool? legacyResetNotice,
  }) => EqState(
    configuration: configuration ?? this.configuration,
    presets: presets ?? this.presets,
    selectedPresetId: identical(selectedPresetId, _keep)
        ? this.selectedPresetId
        : selectedPresetId as String?,
    originPresetId: identical(originPresetId, _keep)
        ? this.originPresetId
        : originPresetId as String?,
    workspaces: workspaces ?? this.workspaces,
    draftPersisted: draftPersisted ?? this.draftPersisted,
    application: application ?? this.application,
    pending: pending ?? this.pending,
    failure: failure,
    legacyResetNotice: legacyResetNotice ?? this.legacyResetNotice,
    recoveryMessage: recoveryMessage,
  );
}

/// Keeps installation-wide EQ drafts independent from general settings saves.
class EqController extends AsyncNotifier<EqState> {
  Future<void> _lane = Future<void>.value();
  StreamSubscription<EqApplicationState>? _subscription;
  Timer? _refreshTimer;
  int _generation = 0;
  int _engineEpoch = 0;
  int _refreshAttempts = 0;
  final _undo = <String, List<EqConfiguration>>{};
  final _redo = <String, List<EqConfiguration>>{};
  EqConfiguration? _gestureStart;
  String? _gestureKey;
  int _previewToken = 0;
  int _previewRevision = 0;
  _GraphEdit? _graphEdit;
  Timer? _checkpointTimer;
  EqState? _checkpointPending;
  bool _checkpointRunning = false;
  _AudioPreview? _latestPreview;
  bool _previewRunning = false;
  int _previewCommands = 0;
  int _workspaceWrites = 0;
  Map<String, Object> get interactionDiagnostics => {
    'previewCommands': _previewCommands,
    'workspaceWrites': _workspaceWrites,
    'previewInFlight': _previewRunning,
    'previewPending': _latestPreview != null,
    'checkpointInFlight': _checkpointRunning,
    'checkpointPending': _checkpointPending != null,
    'graphEditing': _graphEdit != null,
  };

  /// Starts one recoverable graph gesture in the current preset and mode.
  int beginGraphEdit() {
    _clearGraphEdit();
    final current = state.requireValue;
    final token = ++_previewToken;
    _graphEdit = _GraphEdit(token, current.workspaceId, current.configuration);
    return token;
  }

  bool graphEditIsCurrent(int token) =>
      ref.mounted &&
      _graphEdit?.token == token &&
      token == _previewToken &&
      _graphEdit?.workspaceId == state.requireValue.workspaceId &&
      _graphEdit?.start.mode == state.requireValue.configuration.mode;

  void updateGraphEdit(int token, EqConfiguration configuration) {
    if (!graphEditIsCurrent(token) ||
        !configuration.isValid ||
        configuration.mode != _graphEdit!.start.mode) {
      return;
    }
    final previous = state.requireValue;
    if (configuration == previous.configuration) return;
    _generation++;
    state = AsyncData(
      previous.copyWith(
        configuration: configuration,
        workspaces: {
          ...previous.workspaces,
          previous.workspaceId: previous.workspace.edit(configuration),
        },
        draftPersisted: false,
        pending: true,
      ),
    );
    unawaited(preview(configuration, token));
    _checkpointTimer ??= Timer(const Duration(milliseconds: 250), () {
      _checkpointTimer = null;
      if (graphEditIsCurrent(token)) _checkpoint();
    });
  }

  void _checkpoint() {
    _checkpointPending = state.requireValue;
    if (_checkpointRunning) return;
    _checkpointRunning = true;
    unawaited(
      _serialize(() async {
        final snapshot = _checkpointPending;
        _checkpointPending = null;
        if (snapshot == null || !ref.mounted) return;
        final generation = _generation;
        var saved = true;
        try {
          await _persist(snapshot);
        } on Object {
          saved = false;
        }
        if (ref.mounted && generation == _generation) {
          state = AsyncData(
            state.requireValue.copyWith(
              draftPersisted: saved,
              pending: false,
              failure: saved ? state.requireValue.failure : 'Your draft could not be saved. Retry before closing the app.',
            ),
          );
        }
      }).whenComplete(() {
        _checkpointRunning = false;
        if (ref.mounted && _checkpointPending != null && _graphEdit != null) {
          _checkpoint();
        }
      }),
    );
  }

  Future<bool> endGraphEdit(int token, {bool cancel = false}) async {
    if (!graphEditIsCurrent(token)) return false;
    final edit = _graphEdit!;
    _clearGraphEdit(recordUndo: !cancel);
    final current = state.requireValue;
    return _transition(
      cancel
          ? current.copyWith(
              configuration: edit.start,
              workspaces: {
                ...current.workspaces,
                current.workspaceId: current.workspace.edit(edit.start),
              },
            )
          : current,
    );
  }

  void _clearGraphEdit({bool recordUndo = true}) {
    final edit = _graphEdit;
    if (edit != null &&
        recordUndo &&
        edit.workspaceId == state.requireValue.workspaceId &&
        edit.start.mode == state.requireValue.configuration.mode &&
        !sameEqCurve(edit.start, state.requireValue.configuration)) {
      _record(edit.start);
    }
    _graphEdit = null;
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    _checkpointPending = null;
  }

  Future<void> flushEdits() async {
    final edit = _graphEdit;
    if (edit != null) await endGraphEdit(edit.token);
    await _lane;
  }

  String get _historyKey =>
      '${state.requireValue.workspaceId}:${state.requireValue.configuration.mode.name}';
  bool get canUndo => _undo[_historyKey]?.isNotEmpty ?? false;
  bool get canRedo => _redo[_historyKey]?.isNotEmpty ?? false;
  void beginGesture() {
    _gestureStart = state.requireValue.configuration;
    _gestureKey = _historyKey;
  }

  void endGesture() {
    final start = _gestureStart;
    if (start != null &&
        _gestureKey == _historyKey &&
        !sameEqCurve(start, state.requireValue.configuration)) {
      _record(start);
      state = AsyncData(
        state.requireValue.copyWith(failure: state.requireValue.failure),
      );
    }
    _gestureStart = null;
    _gestureKey = null;
  }

  void _record(EqConfiguration configuration) {
    final history = _undo.putIfAbsent(_historyKey, () => []);
    history.add(configuration);
    if (history.length > 50) history.removeAt(0);
    _redo.remove(_historyKey);
  }

  @override
  Future<EqState> build() async {
    ref.onDispose(() {
      _generation++;
      _engineEpoch++;
      _refreshTimer?.cancel();
      _checkpointTimer?.cancel();
      _latestPreview?.completion.complete(false);
      _latestPreview = null;
      unawaited(_subscription?.cancel());
    });
    ref.listen(audioHandlerProvider, (previous, next) {
      if (!identical(previous, next)) {
        _engineEpoch++;
        _refreshTimer?.cancel();
        unawaited(_subscription?.cancel());
        if (next != null) unawaited(_attach(next));
      }
    });
    final loaded = await ref.read(eqRepositoryProvider).load();
    final value = EqState(
      configuration: loaded.configuration,
      presets: loaded.presets,
      workspaces: loaded.workspaces,
      selectedPresetId: loaded.selectedPresetId,
      originPresetId: loaded.originPresetId,
      legacyResetNotice: loaded.legacyResetNotice,
      recoveryMessage: loaded.recoveryMessage,
    );

    final handler = ref.read(audioHandlerProvider);
    if (handler != null) unawaited(_attach(handler));
    return value;
  }

  Future<void> _attach(NavisPlaybackHandler handler) async {
    if (state.asData == null) await future;
    await _serialize(() async {
      if (!ref.mounted || !identical(ref.read(audioHandlerProvider), handler)) {
        return;
      }
      final epoch = ++_engineEpoch;
      try {
        if (handler.equalizerCapabilities.supported) {
          await handler.setEqualizer(state.requireValue.configuration);
        }
      } on Object {
        if (ref.mounted && epoch == _engineEpoch) {
          state = AsyncData(
            state.requireValue.copyWith(
              failure:
                  'EQ could not be applied. Your saved settings are retained.',
            ),
          );
        }
      }
      if (!ref.mounted || epoch != _engineEpoch) return;
      _subscription = handler.equalizerStateStream.listen((application) {
        if (!ref.mounted || epoch != _engineEpoch) return;
        state = AsyncData(
          state.requireValue.copyWith(
            application: application,
            pending: state.requireValue.pending,
            failure: state.requireValue.failure,
          ),
        );
        if (application.pending) _refreshSoon(handler, epoch);
      });
      try {
        await handler.refreshEqualizerState();
      } on Object {
        if (ref.mounted && epoch == _engineEpoch) {
          _fail('EQ status could not be refreshed.');
        }
      }
    });
  }

  void _refreshSoon(NavisPlaybackHandler handler, int epoch) {
    _refreshTimer?.cancel();
    if (_refreshAttempts++ >= 20) return;
    _refreshTimer = Timer(const Duration(milliseconds: 100), () {
      if (ref.mounted && epoch == _engineEpoch) {
        unawaited(handler.refreshEqualizerState().catchError((Object _) {}));
      }
    });
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _lane.then((_) => action());
    _lane = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<bool> setConfiguration(
    EqConfiguration configuration, {
    String? presetId,
    bool recordUndo = true,
  }) async {
    if (state.asData == null) await future;
    if (!ref.mounted || !configuration.isValid) return false;
    final previous = state.requireValue;
    final id = presetId ?? previous.selectedPresetId;
    if (recordUndo &&
        _graphEdit == null &&
        _gestureStart == null &&
        configuration.mode == previous.configuration.mode &&
        !sameEqCurve(configuration, previous.configuration)) {
      _record(previous.configuration);
    }
    final key = id ?? eqCustomWorkspace;
    final workspace =
        (previous.workspaces[key] ??
                EqWorkspace.fromConfiguration(configuration))
            .edit(configuration);
    return _transition(
      previous.copyWith(
        configuration: configuration,
        selectedPresetId: id,
        originPresetId: id,
        workspaces: {...previous.workspaces, key: workspace},
      ),
    );
  }

  Future<bool> _transition(EqState next) {
    _clearGraphEdit();
    final generation = ++_generation;
    final transitionToken = ++_previewToken;
    state = AsyncData(next.copyWith(pending: true, draftPersisted: false));
    return _serialize(() async {
      var persisted = true;
      var applied = true;
      try {
        await _persist(next);
      } on Object {
        persisted = false;
      }
      if (!ref.mounted) return false;
      // Every workspace write is serialized. Only the newest requested curve
      // needs native application; old callbacks never replace newer UI state.
      if (generation == _generation && transitionToken == _previewToken) {
        try {
          final handler = ref.read(audioHandlerProvider);
          if (handler?.equalizerCapabilities.supported == true) {
            await handler!.setEqualizer(next.configuration);
          }
        } on Object {
          applied = false;
        }
      }
      if (ref.mounted && generation == _generation) {
        state = AsyncData(
          state.requireValue.copyWith(
            pending: false,
            draftPersisted: persisted,
            application: ref.read(audioHandlerProvider)?.equalizerState,
            failure: !persisted
                ? 'Your draft could not be saved. Retry before closing the app.'
                : !applied
                ? 'Your draft is saved, but EQ could not be applied. Retry to hear it.'
                : null,
          ),
        );
        final handler = ref.read(audioHandlerProvider);
        if (handler != null &&
            state.requireValue.application?.pending == true) {
          _refreshSoon(handler, _engineEpoch);
        }
      }
      return persisted && applied;
    });
  }

  Future<void> _persist(EqState value) {
    _workspaceWrites++;
    return ref
        .read(eqRepositoryProvider)
        .saveConfiguration(
          configuration: value.configuration,
          selectedPresetId: value.selectedPresetId,
          originPresetId: value.selectedPresetId,
          workspaces: value.workspaces,
        );
  }

  Future<bool> retry() async {
    if (state.asData == null) await future;
    return _transition(state.requireValue);
  }

  Future<bool> selectPreset(EqPreset preset, {bool? enable}) async {
    if (state.asData == null) await future;
    final current = state.requireValue;
    final stored = current.allPresets
        .where((p) => p.id == preset.id)
        .firstOrNull;
    if (stored == null) return false;
    final workspace =
        current.workspaces[preset.id] ??
        EqWorkspace.fromConfiguration(stored.configuration);
    return _transition(
      current.copyWith(
        configuration: workspace.configuration.copyWith(
          enabled: enable ?? current.configuration.enabled,
        ),
        selectedPresetId: preset.id,
        originPresetId: preset.id,
        workspaces: {...current.workspaces, preset.id: workspace},
      ),
    );
  }

  Future<bool> selectCustom() async {
    if (state.asData == null) await future;
    final current = state.requireValue;
    final workspace = current.workspaces[eqCustomWorkspace];
    if (workspace == null) return false;
    return _transition(
      current.copyWith(
        configuration: workspace.configuration.copyWith(
          enabled: current.configuration.enabled,
        ),
        selectedPresetId: null,
        originPresetId: null,
      ),
    );
  }

  Future<bool> changeMode(EqMode mode) async {
    if (state.asData == null) await future;
    final current = state.requireValue;
    return setConfiguration(
      current.workspace
          .changeMode(mode)
          .configuration
          .copyWith(enabled: current.configuration.enabled),
      recordUndo: false,
    );
  }

  Future<bool> setEnabled({required bool enabled}) async {
    if (state.asData == null) await future;
    return setConfiguration(
      state.requireValue.configuration.copyWith(enabled: enabled),
      recordUndo: false,
    );
  }

  bool previewIsCurrent(int token) => ref.mounted && token == _previewToken;
  int beginPreview() => ++_previewToken;
  Future<bool> preview(EqConfiguration configuration, int token) {
    if (!previewIsCurrent(token) || !configuration.isValid) {
      return Future.value(false);
    }
    final request = _AudioPreview(configuration, token, ++_previewRevision);
    _latestPreview?.completion.complete(true);
    _latestPreview = request;
    if (!_previewRunning) unawaited(_drainPreviews());
    return request.completion.future;
  }

  Future<void> _drainPreviews() async {
    _previewRunning = true;
    while (ref.mounted && _latestPreview != null) {
      // One in-flight command and one replaceable pending command bound the
      // native queue independently of pointer-event and storage throughput.
      await Future<void>.delayed(const Duration(milliseconds: 33));
      if (!ref.mounted || _latestPreview == null) break;
      final request = _latestPreview!;
      _latestPreview = null;
      var applied = false;
      if (previewIsCurrent(request.token)) {
        try {
          final handler = ref.read(audioHandlerProvider);
          if (handler?.equalizerCapabilities.supported == true) {
            _previewCommands++;
            await handler!.setEqualizer(request.configuration);
          }
          applied = true;
        } on Object {
          if (previewIsCurrent(request.token) &&
              request.revision == _previewRevision) {
            _fail('Preview could not be applied. Your edits are retained.');
          }
        }
      }
      request.completion.complete(applied);
    }
    _previewRunning = false;
  }

  Future<void> cancelPreview(int token) async {
    if (!ref.mounted || token != _previewToken) return;
    final restore = state.requireValue.configuration;
    final next = ++_previewToken;
    await preview(restore, next);
  }

  Future<bool> discardChanges() async {
    if (state.asData == null) await future;
    final current = state.requireValue;
    final saved = current.selected ?? EqPreset.builtIns.first;
    final workspaces = {...current.workspaces}..remove(current.workspaceId);
    workspaces[saved.id] = EqWorkspace.fromConfiguration(saved.configuration);
    _undo.removeWhere((key, _) => key.startsWith('${current.workspaceId}:'));
    _redo.removeWhere((key, _) => key.startsWith('${current.workspaceId}:'));
    return _transition(
      current.copyWith(
        configuration: saved.configuration.copyWith(
          enabled: current.configuration.enabled,
        ),
        selectedPresetId: saved.id,
        originPresetId: saved.id,
        workspaces: workspaces,
      ),
    );
  }

  String suggestedName(String base) {
    final names = state.requireValue.allPresets
        .map((p) => p.name.toLowerCase())
        .toSet();
    var name = base.trim().isEmpty ? 'My preset' : base.trim();
    var suffix = 2;
    while (names.contains(name.toLowerCase())) {
      name = '$base ($suffix)';
      suffix++;
    }
    return name;
  }

  bool _nameValid(String name, {String? except}) =>
      name.trim().isNotEmpty &&
      name.trim().length <= 120 &&
      !state.requireValue.allPresets.any(
        (p) =>
            p.id != except && p.name.toLowerCase() == name.trim().toLowerCase(),
      );

  Future<EqPreset?> saveAs(
    String name, {
    EqPreset? imported,
    bool activate = true,
    bool enable = false,
  }) async {
    if (state.asData == null) await future;
    return _serialize(() async {
      if (!_nameValid(name)) {
        _fail('Choose a unique preset name of 1–120 characters.');
        return null;
      }
      final current = state.requireValue;
      final preset = EqPreset(
        id: const Uuid().v4(),
        name: name.trim(),
        configuration: imported?.configuration ?? current.configuration,
        source: imported?.source ?? current.selected?.source,
      );
      final workspaces = {...current.workspaces};
      if (activate) {
        // Saving a draft consumes the active variant; other modes remain with
        // their original workspace.
        final original = current.workspace;
        final retained = {...original.curves}
          ..remove(current.configuration.mode);
        if (imported == null && retained.isNotEmpty) {
          workspaces[current.workspaceId] = EqWorkspace(
            mode: retained.keys.first,
            curves: retained,
          );
        } else if (imported == null) {
          workspaces.remove(current.workspaceId);
        }
        workspaces[preset.id] = EqWorkspace.fromConfiguration(
          preset.configuration,
        );
      }
      final next = current.copyWith(
        presets: [...current.presets, preset],
        workspaces: workspaces,
        configuration: activate
            ? preset.configuration.copyWith(
                enabled: enable || current.configuration.enabled,
              )
            : current.configuration,
        selectedPresetId: activate ? preset.id : current.selectedPresetId,
        originPresetId: activate ? preset.id : current.selectedPresetId,
      );
      try {
        await ref
            .read(eqRepositoryProvider)
            .savePresetAndConfiguration(
              preset: preset,
              configuration: next.configuration,
              selectedPresetId: next.selectedPresetId,
              originPresetId: next.selectedPresetId,
              workspaces: next.workspaces,
            );
      } on Object {
        _fail('The preset could not be saved. Your draft is retained.');
        return null;
      }
      if (!ref.mounted) return preset;
      state = AsyncData(next);
      return preset;
    }).then((preset) async {
      if (preset != null && activate) await retry();
      return preset;
    });
  }

  Future<bool> rename(EqPreset preset, String name) async {
    if (state.asData == null) await future;
    return _serialize(() async {
      if (preset.builtIn || !_nameValid(name, except: preset.id)) {
        _fail('Choose a unique preset name of 1–120 characters.');
        return false;
      }
      final stored = state.requireValue.presets
          .where((p) => p.id == preset.id)
          .firstOrNull;
      if (stored == null) return false;
      return _replacePreset(stored.copyWith(name: name.trim()));
    });
  }

  Future<bool> updatePreset() async {
    if (state.asData == null) await future;
    return _serialize(() async {
      final current = state.requireValue;
      final origin = current.origin;
      if (origin == null || origin.builtIn) return false;
      final preset = origin.copyWith(configuration: current.configuration);
      try {
        await ref
            .read(eqRepositoryProvider)
            .savePresetAndConfiguration(
              preset: preset,
              configuration: current.configuration,
              selectedPresetId: preset.id,
              originPresetId: preset.id,
              workspaces: current.workspaces,
            );
        final next = current.copyWith(
          presets: current.presets
              .map((p) => p.id == preset.id ? preset : p)
              .toList(),
          selectedPresetId: preset.id,
          originPresetId: preset.id,
        );

        state = AsyncData(next);
        return true;
      } on Object {
        _fail('The preset could not be updated. Try again.');
        return false;
      }
    });
  }

  Future<bool> _replacePreset(EqPreset preset) async {
    try {
      await ref.read(eqRepositoryProvider).savePreset(preset);
      final next = state.requireValue.copyWith(
        presets: state.requireValue.presets
            .map((p) => p.id == preset.id ? preset : p)
            .toList(),
      );

      state = AsyncData(next);
      return true;
    } on Object {
      _fail('The preset could not be saved. Try again.');
      return false;
    }
  }

  Future<EqPreset?> preserveDraftAs(EqPreset preset, String name) async {
    if (state.asData == null) await future;
    return _serialize(() async {
      if (!_nameValid(name)) {
        _fail('Choose a unique preset name of 1–120 characters.');
        return null;
      }
      final current = state.requireValue;
      final workspace = current.workspaces[preset.id];
      if (workspace == null) return null;
      final replacement = EqPreset(
        id: const Uuid().v4(),
        name: name.trim(),
        configuration: workspace.configuration,
        source: preset.source,
      );
      final next = current.copyWith(
        presets: [...current.presets, replacement],
        workspaces: {...current.workspaces, replacement.id: workspace},
        selectedPresetId: current.selectedPresetId == preset.id
            ? replacement.id
            : current.selectedPresetId,
        originPresetId: current.selectedPresetId == preset.id
            ? replacement.id
            : current.selectedPresetId,
      );
      try {
        await ref
            .read(eqRepositoryProvider)
            .savePresetAndConfiguration(
              preset: replacement,
              configuration: next.configuration,
              selectedPresetId: next.selectedPresetId,
              originPresetId: next.selectedPresetId,
              workspaces: next.workspaces,
            );
        if (ref.mounted) state = AsyncData(next);
        return replacement;
      } on Object {
        _fail('The drafts could not be saved.');
        return null;
      }
    });
  }

  Future<bool> deletePreset(
    EqPreset preset, {
    bool discardDrafts = false,
  }) async {
    if (state.asData == null) await future;
    return _serialize(() async {
      if (preset.builtIn) return false;
      if (state.requireValue.hasDraft(preset.id) && !discardDrafts) {
        _fail(
          'Save the draft as a new preset or explicitly discard it before deleting.',
        );
        return false;
      }
      final current = state.requireValue;
      final custom = current.workspaces[eqCustomWorkspace];
      if (current.selectedPresetId == preset.id &&
          custom != null &&
          !sameEqCurve(custom.configuration, current.configuration)) {
        _fail(
          'Switch to another preset before deleting this one to keep your Custom draft.',
        );
        return false;
      }
      final remaining = {...current.workspaces}..remove(preset.id);
      if (current.selectedPresetId == preset.id) {
        remaining[eqCustomWorkspace] = EqWorkspace.fromConfiguration(
          current.configuration,
        );
      }
      final next = current.copyWith(
        presets: current.presets.where((p) => p.id != preset.id).toList(),
        workspaces: remaining,
        selectedPresetId: current.selectedPresetId == preset.id
            ? null
            : current.selectedPresetId,
        originPresetId: current.originPresetId == preset.id
            ? null
            : current.originPresetId,
      );
      try {
        await ref
            .read(eqRepositoryProvider)
            .deletePresetAndConfiguration(
              id: preset.id,
              configuration: next.configuration,
              selectedPresetId: next.selectedPresetId,
              originPresetId: next.originPresetId,
              workspaces: next.workspaces,
            );

        state = AsyncData(next);
        return true;
      } on Object {
        _fail('The preset could not be deleted. Try again.');
        return false;
      }
    });
  }

  Future<bool> restorePreset(EqPreset preset) async {
    if (state.asData == null) await future;
    return _serialize(() async {
      if (state.requireValue.presets.any((p) => p.id == preset.id)) {
        return false;
      }
      try {
        await ref.read(eqRepositoryProvider).savePreset(preset);
        final next = state.requireValue.copyWith(
          presets: [...state.requireValue.presets, preset],
        );

        state = AsyncData(next);
        return true;
      } on Object {
        _fail('The preset could not be restored. Its name may be in use.');
        return false;
      }
    });
  }

  Future<void> undo() async {
    if (!canUndo) return;
    final key = _historyKey;
    final previous = _undo[key]!.removeLast();
    (_redo[key] ??= []).add(state.requireValue.configuration);
    await setConfiguration(
      previous.copyWith(enabled: state.requireValue.configuration.enabled),
      recordUndo: false,
    );
  }

  Future<void> redo() async {
    if (!canRedo) return;
    final key = _historyKey;
    final next = _redo[key]!.removeLast();
    (_undo[key] ??= []).add(state.requireValue.configuration);
    await setConfiguration(
      next.copyWith(enabled: state.requireValue.configuration.enabled),
      recordUndo: false,
    );
  }

  Future<void> reset() async {
    if (state.asData == null) await future;
    await setConfiguration(EqConfiguration.flat());
  }

  Future<void> acknowledgeLegacyReset() async {
    if (state.asData == null) await future;
    await ref.read(eqRepositoryProvider).acknowledgeLegacyReset();
    if (ref.mounted) {
      state = AsyncData(state.requireValue.copyWith(legacyResetNotice: false));
    }
  }

  void _fail(String message) {
    if (ref.mounted) {
      state = AsyncData(state.requireValue.copyWith(failure: message));
    }
  }
}

final equalizerProvider = AsyncNotifierProvider<EqController, EqState>(
  EqController.new,
);

class _GraphEdit {
  const _GraphEdit(this.token, this.workspaceId, this.start);
  final int token;
  final String workspaceId;
  final EqConfiguration start;
}

class _AudioPreview {
  _AudioPreview(this.configuration, this.token, this.revision);
  final EqConfiguration configuration;
  final int token;
  final int revision;
  final completion = Completer<bool>();
}
