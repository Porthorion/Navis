import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';

import 'dart:convert';

import 'package:navis/src/database/daos/eq_dao.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

class EqStoredState {
  EqStoredState({
    required this.configuration,
    required List<EqPreset> presets,
    this.workspaces = const {},
    this.selectedPresetId,
    this.originPresetId,
    this.legacyResetNotice = false,
    this.recoveryMessage,
  }) : presets = List.unmodifiable(presets);

  final Map<String, EqWorkspace> workspaces;
  final EqConfiguration configuration;
  final List<EqPreset> presets;
  final String? selectedPresetId;
  final String? originPresetId;
  final bool legacyResetNotice;
  final String? recoveryMessage;
}

class EqRepository {
  EqRepository(this._dao);

  final EqDao _dao;

  Future<EqStoredState> load() async {
    final rows = await _dao.getPresets();
    final current = await _dao.getState();
    final presets = <EqPreset>[];
    var recovered = false;
    for (final row in rows) {
      try {
        final preset = EqPreset.fromJson(
          jsonDecode(row.presetJson) as Map<String, dynamic>,
        );
        if (preset.id != row.id ||
            preset.name != row.name ||
            preset.id.startsWith('builtin:')) {
          throw const FormatException('Invalid stored EQ preset.');
        }
        presets.add(preset);
      } on Object {
        // Keep damaged records in storage for recovery. Loading never silently
        // rewrites the library or turns broken settings into enabled audio.
        recovered = true;
      }
    }
    var configuration = EqConfiguration.flat();
    final raw = current?.configurationJson;
    if (raw != null) {
      try {
        configuration = EqConfiguration.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } on Object {
        recovered = true;
      }
    }
    final all = [...EqPreset.builtIns, ...presets];
    final selected = all.where((p) => p.id == current?.selectedPresetId);
    final matches =
        selected.isNotEmpty &&
        selected.first.configuration.copyWith(enabled: configuration.enabled) ==
            configuration;
    final workspaces = <String, EqWorkspace>{};
    String? identity;
    if (current?.workspacesJson != null) {
      try {
        final json =
            jsonDecode(current!.workspacesJson!) as Map<String, dynamic>;
        for (final entry in json.entries) {
          try {
            workspaces[entry.key] = EqWorkspace.fromJson(
              entry.value as Map<String, dynamic>,
            );
          } on Object {
            recovered = true;
          }
        }
        identity = all.any((p) => p.id == current.selectedPresetId)
            ? current.selectedPresetId
            : all.any((p) => p.id == current.originPresetId)
            ? current.originPresetId
            : null;
      } on Object {
        recovered = true;
      }
    } else {
      identity = matches
          ? current?.selectedPresetId
          : all.any((p) => p.id == current?.originPresetId)
          ? current?.originPresetId
          : null;
      if (current?.configurationJson == null) identity = 'builtin:flat';
      workspaces[identity ?? eqCustomWorkspace] = EqWorkspace.fromConfiguration(
        configuration,
      );
    }
    // The separately persisted current curve is the recovery point if a draft
    // record is damaged. Do not silently replace it with a saved preset.
    workspaces.putIfAbsent(
      identity ?? eqCustomWorkspace,
      () => EqWorkspace.fromConfiguration(configuration),
    );
    return EqStoredState(
      configuration: configuration,
      presets: presets,
      workspaces: workspaces,
      selectedPresetId: identity,
      originPresetId: identity,
      legacyResetNotice: current?.legacyResetNotice ?? false,
      recoveryMessage: recovered
          ? 'Some saved EQ data could not be loaded. The damaged records '
                'have been retained; review your settings before enabling EQ.'
          : null,
    );
  }

  Future<void> saveConfiguration({
    required EqConfiguration configuration,
    required String? selectedPresetId,
    required String? originPresetId,
    Map<String, EqWorkspace>? workspaces,
  }) {
    if (!configuration.isValid) {
      throw ArgumentError('Invalid equalizer configuration');
    }
    return _dao.saveState(
      configurationJson: jsonEncode(configuration.toJson()),
      selectedPresetId: selectedPresetId,
      originPresetId: originPresetId,
      workspacesJson: workspaces == null
          ? null
          : jsonEncode({
              for (final e in workspaces.entries) e.key: e.value.toJson(),
            }),
    );
  }

  Future<void> savePreset(EqPreset preset) {
    if (preset.builtIn ||
        preset.id.isEmpty ||
        preset.id.startsWith('builtin:') ||
        preset.name.trim().isEmpty ||
        preset.name.length > 120 ||
        !preset.configuration.isValid) {
      throw ArgumentError('Invalid saved preset');
    }
    return _dao.savePreset(
      id: preset.id,
      name: preset.name.trim(),
      presetJson: jsonEncode(
        preset.copyWith(name: preset.name.trim()).toJson(),
      ),
    );
  }

  Future<void> deletePreset(String id) => _dao.deletePreset(id);

  Future<void> acknowledgeLegacyReset() => _dao.acknowledgeLegacyReset();

  Future<void> savePresetAndConfiguration({
    required EqPreset preset,
    required EqConfiguration configuration,
    required String? selectedPresetId,
    required String? originPresetId,
    Map<String, EqWorkspace>? workspaces,
  }) => _dao.attachedDatabase.transaction(() async {
    await savePreset(preset);
    await saveConfiguration(
      configuration: configuration,
      selectedPresetId: selectedPresetId,
      originPresetId: originPresetId,
      workspaces: workspaces,
    );
  });

  Future<void> deletePresetAndConfiguration({
    required String id,
    required EqConfiguration configuration,
    required String? selectedPresetId,
    required String? originPresetId,
    Map<String, EqWorkspace>? workspaces,
  }) => _dao.attachedDatabase.transaction(() async {
    await deletePreset(id);
    await saveConfiguration(
      configuration: configuration,
      selectedPresetId: selectedPresetId,
      originPresetId: originPresetId,
      workspaces: workspaces,
    );
  });
}
