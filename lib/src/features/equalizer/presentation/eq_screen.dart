import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/features/equalizer/presentation/eq_import_messages.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/equalizer/data/eq_import_parser.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_band_inspector.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_editor.dart';
import 'package:navis/src/features/equalizer/presentation/eq_quick_panel.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_painter.dart';
import 'package:navis/src/features/equalizer/presentation/eq_import_dialogs.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_tokens.dart';

export 'package:navis/src/features/equalizer/presentation/eq_band_inspector.dart'
    show eqModeLabel;

class EqualizerScreen extends ConsumerStatefulWidget {
  const new({super.key});
  @override
  ConsumerState<EqualizerScreen> createState() => EqualizerScreenState();
}

/// Owns selection and temporary text input; persistent curves belong to Riverpod.
class EqualizerScreenState extends ConsumerState<EqualizerScreen> {
  EqController get controller => ref.read(equalizerProvider.notifier);
  AppLocalizations get l10n => AppLocalizations.of(context)!;
  bool _importing = false;
  bool _libraryVisible = false;
  EqPreset? _deletedPreset;
  int _activeBand = 0;
  String? _bandIdentity;
  final _graph = GlobalKey<EqGraphEditorState>();
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  String? _parameter;
  EqConfiguration? _numberBase;
  EqConfiguration? _numberPreview;
  int? _numberToken;
  int? _numberBand;
  int? _graphToken;
  bool _inputTouched = false;
  String? _inputError;
  late final AppLifecycleListener _lifecycle;
  late final EqController _owner;

  @override
  void initState() {
    super.initState();
    _owner = controller;
    _lifecycle = AppLifecycleListener(onInactive: () => unawaited(_flush()));
  }

  Future<void> _flush() async {
    if (_parameter != null) await cancelNumber();
    await _owner.flushEdits();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    final token = _numberToken;
    if (token != null) unawaited(_owner.cancelPreview(token));
    unawaited(_owner.flushEdits());
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  int? _selected(EqState value) {
    if (value.configuration.filters.isEmpty) return null;
    final identity = '${value.workspaceId}:${value.configuration.mode.name}';
    return _bandIdentity == identity
        ? _activeBand.clamp(0, value.configuration.filters.length - 1)
        : 0;
  }

  void selectBand(int index) {
    if (_parameter != null) return;
    final value = ref.read(equalizerProvider).requireValue;
    if (index < 0 || index >= value.configuration.filters.length) return;
    setState(() {
      _activeBand = index;
      _bandIdentity = '${value.workspaceId}:${value.configuration.mode.name}';
    });
  }

  void dragBand(int index, double dx, double dy, {bool cancel = false}) =>
      _graph.currentState?.dragBand(index, dx, dy, cancel: cancel);

  Future<void> flushGraphEdits() => controller.flushEdits();

  Future<Map<String, Object>> profileGraph(int index) async {
    final result = await _graph.currentState!.profileDrag(index);
    await controller.flushEdits();
    return result;
  }

  void editNumber(String parameter) {
    if (_parameter != null) return;
    final value = ref.read(equalizerProvider).requireValue;
    final config = value.configuration;
    final index = _selected(value);
    final filter = index == null ? null : config.filters[index];
    if (parameter != EqParameter.preamp && filter == null) return;
    if ((parameter == EqParameter.frequency || parameter == EqParameter.q) &&
        config.mode != EqMode.advanced) {
      return;
    }
    if (parameter == EqParameter.gain && !filter!.usesGain) return;
    _graph.currentState?.settleWheel();
    if (!const {
      EqParameter.frequency,
      EqParameter.gain,
      EqParameter.q,
      EqParameter.preamp,
    }.contains(parameter)) {
      return;
    }
    final number = switch (parameter) {
      EqParameter.frequency => filter!.frequencyHz,
      EqParameter.gain => filter!.gainDb,
      EqParameter.q => filter!.q,
      _ => config.preampDb,
    };
    setState(() {
      _parameter = parameter;
      _numberBase = config;
      _numberPreview = config;
      _numberBand = index;
      _numberToken = controller.beginPreview();
      _inputTouched = false;
      _inputError = null;
      _input.text = eqNumber(number, decimals: EqParameter.decimals(parameter));
    });
    if (parameter == EqParameter.preamp) {
      _graph.currentState?.revealOutputResponse();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _parameter != null) {
        _inputFocus.requestFocus();
        _input.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _input.text.length,
        );
      }
    });
  }

  EqConfiguration? _typedConfiguration() {
    if (!_inputTouched) return _numberBase;
    final number = double.tryParse(_input.text.trim().replaceAll(',', '.'));
    final (minimum, maximum) = EqParameter.range(_parameter!);
    if (number == null ||
        !number.isFinite ||
        number < minimum ||
        number > maximum) {
      return null;
    }
    final base = _numberBase!;
    if (_parameter == EqParameter.preamp) {
      return base.copyWith(preampDb: number);
    }
    final filters = [...base.filters];
    final filter = filters[_numberBand!];
    filters[_numberBand!] = switch (_parameter) {
      EqParameter.frequency => filter.copyWith(frequencyHz: number),
      EqParameter.gain => filter.copyWith(gainDb: number),
      _ => filter.copyWith(q: number),
    };
    return base.copyWith(filters: filters);
  }

  Future<void> typeNumber(String value) async {
    if (_parameter == null) return;
    // Reassigning identical text would reset the caret while typing.
    if (_input.text != value) _input.text = value;
    _inputTouched = true;
    final config = _typedConfiguration();
    setState(() {
      _inputError = config == null ? l10n.eqNumberInvalid : null;
      if (config != null) _numberPreview = config;
    });
    if (config != null) await controller.preview(config, _numberToken!);
  }

  void _nudgeNumber(int direction) {
    final valid = _typedConfiguration() ?? _numberPreview!;
    final filter = _numberBand == null ? null : valid.filters[_numberBand!];
    final value = switch (_parameter) {
      EqParameter.frequency => filter!.frequencyHz,
      EqParameter.gain => filter!.gainDb,
      EqParameter.q => filter!.q,
      _ => valid.preampDb,
    };
    final step = switch (_parameter) {
      EqParameter.frequency => 1.0,
      EqParameter.q => .001,
      _ => .01,
    };
    final (minimum, maximum) = EqParameter.range(_parameter!);
    unawaited(
      typeNumber((value + direction * step).clamp(minimum, maximum).toString()),
    );
  }

  Future<void> finishNumber() async {
    if (_parameter == null) return;
    final config = _typedConfiguration();
    if (config == null) {
      setState(() => _inputError = l10n.eqNumberInvalid);
      return;
    }
    final token = _numberToken!;
    if (!controller.previewIsCurrent(token)) {
      await cancelNumber();
      return;
    }
    _inputFocus.unfocus();
    setState(() {
      _parameter = null;
      _numberPreview = null;
      _numberToken = null;
    });
    await controller.setConfiguration(config);
  }

  Future<void> cancelNumber() async {
    if (_parameter == null) return;
    final token = _numberToken!;
    _inputFocus.unfocus();
    if (mounted) {
      setState(() {
        _parameter = null;
        _numberPreview = null;
        _numberToken = null;
      });
    }
    await controller.cancelPreview(token);
  }

  void _beginGraph() {
    _graph.currentState?.settleWheel();
    _graphToken = controller.beginGraphEdit();
  }

  void _updateGraph(EqConfiguration config) {
    final token = _graphToken;
    if (token != null) controller.updateGraphEdit(token, config);
  }

  void _endGraph({bool cancel = false}) {
    final token = _graphToken;
    _graphToken = null;
    if (token != null) {
      unawaited(controller.endGraphEdit(token, cancel: cancel));
    }
  }

  void _updateQ(int index, double q) {
    final current = ref.read(equalizerProvider).requireValue.configuration;
    if (index >= current.filters.length) return;
    final filters = [...current.filters];
    filters[index] = filters[index].copyWith(q: q);
    _updateGraph(current.copyWith(filters: filters));
  }

  bool _wide(AdaptiveContext adaptive, double width) =>
      (adaptive.desktopWide ||
          adaptive.adaptiveLayoutClass == AdaptiveLayoutClass.tabletExpanded) &&
      width >= 850 &&
      MediaQuery.textScalerOf(context).scale(1) <= 1.4;

  @override
  Widget build(BuildContext context) {
    final adaptive = resolveAdaptiveContextFor(context);
    final capabilities = ref.watch(eqCapabilitiesProvider);
    final async = capabilities.supported ? ref.watch(equalizerProvider) : null;
    final libraryPanel =
        _wide(adaptive, MediaQuery.sizeOf(context).width) &&
        adaptive.desktopWide &&
        MediaQuery.sizeOf(context).width >= 1200;
    return PopScope(
      canPop: _parameter == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _parameter != null) unawaited(cancelNumber());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.eqTitle),
          leading: adaptive.useDesktopShell
              ? IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () async {
                    if (_parameter != null) {
                      await cancelNumber();
                      return;
                    }
                    // Returns to wherever the page was opened from (for
                    // example the player), not always the Settings root.
                    await NavService.closeEqualizer(context, ref);
                  },
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          actions: [
            if (libraryPanel)
              IconButton(
                tooltip: l10n.eqPresets,
                isSelected: _libraryVisible,
                onPressed: _parameter == null && capabilities.supported
                    ? _presets
                    : null,
                icon: const Icon(Icons.library_music_outlined),
                selectedIcon: const Icon(Icons.library_music),
              ),
            IconButton(
              tooltip: l10n.eqOutputSettings,
              onPressed: _parameter == null && capabilities.supported
                  ? _settings
                  : null,
              icon: const Icon(Icons.tune),
            ),
          ],
        ),
        body: !capabilities.supported
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(l10n.eqUnavailable),
                ),
              )
            : async!.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => Center(
                  child: TextButton(
                    onPressed: () => ref.invalidate(equalizerProvider),
                    child: Text(l10n.commonRetry),
                  ),
                ),
                data: (value) => LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = _wide(adaptive, constraints.maxWidth);
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (wide && _libraryVisible) ...[
                          // Presets cannot change until exact entry resolves.
                          SizedBox(
                            width: 300,
                            child: ExcludeFocus(
                              excluding: _parameter != null,
                              child: AbsorbPointer(
                                absorbing: _parameter != null,
                                child: AnimatedOpacity(
                                  opacity: _parameter != null ? .5 : 1,
                                  duration: const Duration(milliseconds: 120),
                                  child: _library(
                                    value,
                                    close: () =>
                                        setState(() => _libraryVisible = false),
                                    panel: true,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const VerticalDivider(width: 1),
                        ],
                        Expanded(child: _workspace(value, wide: wide)),
                      ],
                    );
                  },
                ),
              ),
      ),
    );
  }

  Widget _workspace(EqState value, {required bool wide}) {
    final editing = _parameter != null;
    return Padding(
      key: const ValueKey('eq-editor'),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, outer) {
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final sideBySide =
              wide ||
              (outer.maxWidth >= 640 &&
                  scale <= 1.4 &&
                  (outer.maxWidth >= 840 ||
                      outer.maxHeight < outer.maxWidth * .75));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!editing || sideBySide)
                ExcludeFocus(
                  excluding: editing,
                  child: AbsorbPointer(
                    absorbing: editing,
                    child: AnimatedOpacity(
                      opacity: editing ? .5 : 1,
                      duration: const Duration(milliseconds: 120),
                      child: _header(
                        value,
                        inline: outer.maxWidth >= 600 && scale <= 1.3,
                      ),
                    ),
                  ),
                ),
              ..._notices(value),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => sideBySide
                      ? _sideBySide(value, constraints, wide: wide)
                      : _stacked(value, constraints),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: _actions(value),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _graphEditor(EqState value, {required bool compact}) {
    final editing = _parameter != null;
    return EqGraphEditor(
      key: _graph,
      configuration: _numberPreview ?? value.configuration,
      selectedBand: _selected(value),
      sampleRate:
          value.application?.responseSampleRate ??
          value.application?.sampleRate ??
          48000,
      compact: compact || editing,
      enabled: !editing,
      onSelect: selectBand,
      onBegin: _beginGraph,
      onChanged: _updateGraph,
      onCommit: _endGraph,
      onCancel: () => _endGraph(cancel: true),
      onPreampInput: () => editNumber(EqParameter.preamp),
    );
  }

  Widget _inspector(
    EqState value, {
    required bool showPreamp,
    bool wide = false,
  }) {
    final config = value.configuration;
    final selected = _selected(value);
    return EqBandInspector(
      configuration: config,
      selected: selected,
      wide: wide,
      showPreamp: showPreamp,
      onSelect: selectBand,
      onEdit: editNumber,
      onUpdateBand: _updateBand,
      onAddBand: () => _addBand(value),
      onDeleteBand: () {
        if (selected == null) return;
        final filters = [...config.filters]..removeAt(selected);
        unawaited(
          controller.setConfiguration(config.copyWith(filters: filters)),
        );
      },
      onEditAdvanced: () => unawaited(_advanced()),
      onQBegin: _beginGraph,
      onQChanged: (q) {
        if (selected != null) _updateQ(selected, q);
      },
      onQEnd: _endGraph,
      onQCancel: () => _endGraph(cancel: true),
    );
  }

  Widget _numberEditor({bool dense = false}) => EqNumberEditor(
    parameter: _parameter!,
    bandNumber: _parameter == EqParameter.preamp || _numberBand == null
        ? null
        : _numberBand! + 1,
    controller: _input,
    focusNode: _inputFocus,
    error: _inputError,
    dense: dense,
    onChanged: typeNumber,
    onSubmitted: () => unawaited(finishNumber()),
    onCancel: () => unawaited(cancelNumber()),
    onNudge: _nudgeNumber,
  );

  Widget _sideBySide(
    EqState value,
    BoxConstraints constraints, {
    required bool wide,
  }) {
    final editing = _parameter != null;
    final inspectorWidth = math
        .min(360, math.max(300, constraints.maxWidth * .34))
        .toDouble();
    final toolbar = constraints.maxHeight >= 260;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _graphEditor(value, compact: !toolbar)),
        const SizedBox(width: 16),
        SizedBox(
          width: inspectorWidth,
          child: editing
              ? SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 4),
                  child: _numberEditor(dense: constraints.maxHeight < 260),
                )
              : _inspector(value, showPreamp: !toolbar, wide: wide),
        ),
      ],
    );
  }

  Widget _stacked(EqState value, BoxConstraints constraints) {
    final editing = _parameter != null;
    final height = constraints.maxHeight;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    if (editing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _graphEditor(value, compact: true)),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height * .6),
            child: SingleChildScrollView(
              child: _numberEditor(dense: height < 360),
            ),
          ),
        ],
      );
    }
    final advanced = value.configuration.mode == EqMode.advanced;
    final compactGraph = scale > 1.4 || height < 400;
    final inspector = (advanced ? 236.0 : 184.0) * (1 + (scale - 1) * .5);
    final preferred = compactGraph
        ? math.min(200, height * .42)
        : (height - inspector)
              .clamp(
                math.min(220, height * .5),
                math.min(560, constraints.maxWidth * .75),
              )
              .toDouble();
    final graphHeight = math
        .max(0, math.min(preferred, height - 96 * scale))
        .toDouble();
    final toolbar = !compactGraph && graphHeight >= 200;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: graphHeight,
          child: _graphEditor(value, compact: !toolbar),
        ),
        const SizedBox(height: 12),
        Expanded(child: _inspector(value, showPreamp: !toolbar)),
      ],
    );
  }

  void _addBand(EqState value) {
    final config = value.configuration;
    if (config.filters.length >= EqConfiguration.maximumFilters) return;
    setState(() {
      _activeBand = config.filters.length;
      _bandIdentity = '${value.workspaceId}:${config.mode.name}';
    });
    unawaited(
      controller.setConfiguration(
        config.copyWith(
          filters: [...config.filters, const EqFilter(frequencyHz: 1000)],
        ),
      ),
    );
  }

  String _applicationStatus(EqState value) =>
      eqApplicationStatusLabel(value, l10n);

  Widget _header(EqState value, {required bool inline}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final config = value.configuration;
    final hasDraft = value.hasDraft(value.workspaceId);
    final unsaved = hasDraft && !value.draftPersisted && !value.pending;
    final applied = value.application?.applied.enabled == true;
    final status = [
      _applicationStatus(value),
      if (hasDraft && value.draftPersisted)
        l10n.eqDraftSaved
      else if (hasDraft && value.pending)
        l10n.eqDraftSaving
      else if (hasDraft)
        l10n.eqDraftNotSaved,
    ].join(' · ');
    final name = value.displayName(l10n.eqCustom);
    final preset = TextButton(
      key: const ValueKey('eq-preset-picker'),
      onPressed: _presets,
      style: TextButton.styleFrom(
        foregroundColor: colors.onSurface,
        alignment: AlignmentDirectional.centerStart,
        padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 4, 6),
        shape: RoundedRectangleBorder(borderRadius: NavisRadius.mdAll),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: applied ? colors.primary : null,
                        border: Border.all(
                          color: applied ? colors.primary : colors.outline,
                          width: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: unsaved
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Icon(Icons.expand_more),
        ],
      ),
    );
    final modes = [
      EqMode.simple,
      EqMode.tenBand,
      EqMode.advanced,
      if (config.mode == EqMode.importedFixed ||
          value.workspace.curves.containsKey(EqMode.importedFixed))
        EqMode.importedFixed,
    ];
    final mode = EqModeSelector(
      mode: config.mode,
      modes: modes,
      onChanged: (mode) => unawaited(controller.changeMode(mode)),
    );
    final trailing = [
      if (value.selected != null) _presetMenu(value.selected!),
      Semantics(
        label: l10n.eqEnable,
        child: Switch.adaptive(
          key: const ValueKey('eq-enable'),
          value: config.enabled,
          onChanged: (enabled) =>
              unawaited(controller.setEnabled(enabled: enabled)),
        ),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: inline
          ? Row(
              children: [
                Expanded(
                  child: Tooltip(message: name, child: preset),
                ),
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: mode,
                ),
                const SizedBox(width: 4),
                ...trailing,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Tooltip(message: name, child: preset),
                    ),
                    ...trailing,
                  ],
                ),
                const SizedBox(height: 6),
                mode,
              ],
            ),
    );
  }

  List<Widget> _notices(EqState value) {
    final colors = Theme.of(context).colorScheme;
    Widget notice(String text, {required bool error, VoidCallback? retry}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: error ? colors.errorContainer : colors.secondaryContainer,
            borderRadius: NavisRadius.mdAll,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 4, 4),
              child: Row(
                children: [
                  Icon(
                    error ? Icons.error_outline : Icons.info_outline,
                    size: 20,
                    color: error
                        ? colors.onErrorContainer
                        : colors.onSecondaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: error
                              ? colors.onErrorContainer
                              : colors.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ),
                  if (retry != null)
                    TextButton(onPressed: retry, child: Text(l10n.commonRetry)),
                ],
              ),
            ),
          ),
        );
    final reason = value.application?.reason;
    return [
      if (value.failure != null)
        notice(
          value.failure!,
          error: true,
          retry: () => unawaited(controller.retry()),
        ),
      if (reason != null && value.configuration.enabled)
        notice(reason, error: false),
    ];
  }

  Widget _actions(EqState value) {
    final hasDraft = value.hasDraft(value.workspaceId);
    final userPreset = value.selected?.builtIn == false;
    return EqActionBar(
      editingNumber: _parameter != null,
      canUndo: controller.canUndo,
      canRedo: controller.canRedo,
      onUndo: () => unawaited(controller.undo()),
      onRedo: () => unawaited(controller.redo()),
      saveLabel: value.dirty
          ? (userPreset ? l10n.eqSaveChanges : l10n.eqSaveAs)
          : null,
      onSave: value.pending
          ? null
          : userPreset
          ? () => unawaited(controller.updatePreset())
          : _saveAs,
      onDiscard: hasDraft && !value.pending ? _discard : null,
      onCancelNumber: () => unawaited(cancelNumber()),
      onDoneNumber: () => unawaited(finishNumber()),
    );
  }

  void _updateBand(int index, EqFilter filter) {
    final current = ref.read(equalizerProvider).requireValue.configuration;
    final filters = [...current.filters];
    filters[index] = filter;
    unawaited(controller.setConfiguration(current.copyWith(filters: filters)));
  }

  Future<void> _advanced() async {
    final value = ref.read(equalizerProvider).requireValue;
    final advanced = value.workspace.curves[EqMode.advanced];
    if (advanced == null) {
      await controller.changeMode(EqMode.advanced);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.eqEditAdvanced),
        content: Text(l10n.eqAdvancedDraftExists),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.eqCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'resume'),
            child: Text(l10n.eqResumeAdvanced),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'copy'),
            child: Text(l10n.eqCreateCurvePreset),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'resume') {
      await controller.changeMode(EqMode.advanced);
      return;
    }
    final name = await _name(
      controller.suggestedName(value.selected?.name ?? l10n.eqCustom),
    );
    if (name != null && mounted) {
      await controller.saveAs(
        name,
        imported: EqPreset(
          id: 'preview',
          name: name,
          configuration: value.configuration.copyWith(mode: EqMode.advanced),
          source: value.selected?.source,
        ),
      );
    }
  }

  Future<void> _discard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.eqDiscardChanges),
        content: Text(l10n.eqDiscardDescription),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.eqCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.eqDiscardChanges),
          ),
        ],
      ),
    );
    if (discard == true && mounted) await controller.discardChanges();
  }

  Future<void> _panel(WidgetBuilder builder) async {
    final adaptive = resolveAdaptiveContextFor(context);
    if (adaptive.desktopWide ||
        adaptive.adaptiveLayoutClass == AdaptiveLayoutClass.tabletExpanded) {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: SizedBox(
            width: 480,
            height: MediaQuery.sizeOf(context).height * .8,
            child: builder(context),
          ),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .8,
            child: builder(context),
          ),
        ),
      );
    }
  }

  Future<void> _presets() async {
    final adaptive = resolveAdaptiveContextFor(context);
    if (adaptive.desktopWide &&
        MediaQuery.sizeOf(context).width >= 1200 &&
        MediaQuery.textScalerOf(context).scale(1) <= 1.4) {
      setState(() => _libraryVisible = !_libraryVisible);
      return;
    }
    await _panel(
      (context) => Consumer(
        builder: (context, ref, _) {
          final value = ref.watch(equalizerProvider).asData?.value;
          return value == null
              ? const Center(child: CircularProgressIndicator())
              : _library(value, close: () => Navigator.pop(context));
        },
      ),
    );
  }

  Widget _library(
    EqState value, {
    required VoidCallback close,
    bool panel = false,
  }) {
    final theme = Theme.of(context);
    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    Widget tile(EqPreset preset) {
      final selected = value.selectedPresetId == preset.id;
      final draft = value.hasDraft(preset.id);
      return ListTile(
        key: ValueKey('eq-preset-${preset.id}'),
        selected: selected,
        shape: RoundedRectangleBorder(borderRadius: NavisRadius.mdAll),
        selectedTileColor: theme.colorScheme.surfaceContainerHighest,
        leading: Icon(
          selected
              ? Icons.check
              : preset.builtIn
              ? Icons.graphic_eq
              : preset.source != null
              ? Icons.headphones_outlined
              : Icons.tune,
        ),
        title: Text(
          '${preset.name}${draft ? '*' : ''}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          preset.builtIn
              ? l10n.eqBuiltIn
              : _presetSummary(preset.configuration),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () {
          unawaited(controller.selectPreset(preset));
          if (!panel) close();
        },
        trailing: _presetMenu(preset),
      );
    }

    final user = value.presets;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(l10n.eqPresets, style: theme.textTheme.titleLarge),
              ),
            ),
            if (panel)
              IconButton(
                tooltip: l10n.eqCloseLibrary,
                onPressed: close,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          key: const ValueKey('eq-autoeq'),
          onPressed: _importing ? null : () => unawaited(_import('autoeq')),
          icon: const Icon(Icons.headphones_outlined),
          label: Text(l10n.eqAutoEq),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _importButton(),
            OutlinedButton.icon(
              onPressed: _saveAs,
              icon: const Icon(Icons.add),
              label: Text(l10n.eqSaveAs),
            ),
          ],
        ),
        if (value.hasDraft(eqCustomWorkspace)) ...[
          section(l10n.eqUnsavedWork),
          ListTile(
            key: const ValueKey('eq-preset-custom'),
            shape: RoundedRectangleBorder(borderRadius: NavisRadius.mdAll),
            selectedTileColor: theme.colorScheme.surfaceContainerHighest,
            leading: Icon(
              value.selectedPresetId == null ? Icons.check : Icons.edit_note,
            ),
            title: Text('${l10n.eqCustom}*'),
            selected: value.selectedPresetId == null,
            onTap: () {
              unawaited(controller.selectCustom());
              if (!panel) close();
            },
          ),
        ],
        if (user.isNotEmpty) ...[
          section(l10n.eqYourPresets),
          for (final preset in user) tile(preset),
        ],
        section(l10n.eqBuiltInPresets),
        for (final preset in EqPreset.builtIns) tile(preset),
      ],
    );
  }

  /// Fixed layouts already state their band count; parametric ones need it.
  String _presetSummary(EqConfiguration configuration) =>
      configuration.mode == EqMode.simple ||
          configuration.mode == EqMode.tenBand
      ? eqModeLabel(l10n, configuration.mode)
      : '${eqModeLabel(l10n, configuration.mode)} · ${l10n.eqFilterCount(configuration.filters.length)}';

  Future<void> _settings() => _panel(
    (context) => Consumer(
      builder: (context, ref, _) {
        final value = ref.watch(equalizerProvider).asData?.value;
        if (value == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final attenuation = value.application?.headroomDb ?? 0;
        final preamp = value.configuration.preampDb;
        Widget row(String label, double db, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: strong
                      ? theme.textTheme.titleSmall
                      : theme.textTheme.bodyMedium,
                ),
              ),
              Text(
                '${eqSignedGain(db)} dB',
                style:
                    (strong
                            ? theme.textTheme.titleSmall
                            : theme.textTheme.bodyMedium)
                        ?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
              ),
            ],
          ),
        );
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          children: [
            Text(l10n.eqOutputSettings, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.eqAutoHeadroom),
              subtitle: Text(l10n.eqAutoHeadroomDescription),
              value: value.configuration.autoHeadroom,
              onChanged: (enabled) => unawaited(
                controller.setConfiguration(
                  value.configuration.copyWith(autoHeadroom: enabled),
                ),
              ),
            ),
            if (!value.configuration.autoHeadroom)
              Text(
                l10n.eqClippingRisk,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.error,
                ),
              ),
            const SizedBox(height: 12),
            Card.outlined(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    row(l10n.eqAuthoredPreamp, preamp),
                    row(l10n.eqAttenuation, attenuation),
                    const Divider(),
                    row(
                      l10n.eqEffectiveOutput,
                      preamp + attenuation,
                      strong: true,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.eqOutputExplanation,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (value.application?.reason != null) ...[
              const SizedBox(height: 12),
              Text(value.application!.reason!),
            ],
            if (value.legacyResetNotice)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.eqLegacyReset),
                trailing: TextButton(
                  onPressed: () =>
                      unawaited(controller.acknowledgeLegacyReset()),
                  child: Text(l10n.eqDismiss),
                ),
              ),
            if (value.recoveryMessage != null) Text(value.recoveryMessage!),
            if (_deletedPreset != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () async {
                    if (await controller.restorePreset(_deletedPreset!) &&
                        mounted) {
                      setState(() => _deletedPreset = null);
                    }
                  },
                  icon: const Icon(Icons.undo),
                  label: Text(l10n.eqUndo),
                ),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () => unawaited(
                  controller.setConfiguration(
                    EqConfiguration.flat(
                      mode: value.configuration.mode == EqMode.importedFixed
                          ? EqMode.advanced
                          : value.configuration.mode,
                    ).copyWith(enabled: value.configuration.enabled),
                  ),
                ),
                icon: const Icon(Icons.restart_alt),
                label: Text(l10n.eqReset),
              ),
            ),
            if (value.origin?.source != null) ...[
              const Divider(height: 32),
              Text(l10n.eqSource, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              SelectableText(
                value.origin!.source!.measurementSource ?? 'AutoEQ',
              ),
              if (value.origin!.source!.target != null)
                SelectableText(
                  '${l10n.eqTarget}: ${value.origin!.source!.target!}',
                ),
              if (value.origin!.source!.revision != null)
                SelectableText(value.origin!.source!.revision!),
              if (value.origin!.source!.url != null)
                SelectableText(value.origin!.source!.url!),
              const SizedBox(height: 4),
              Text(
                l10n.eqOriginalSource,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        );
      },
    ),
  );

  PopupMenuButton<String> _presetMenu(EqPreset preset) =>
      PopupMenuButton<String>(
        tooltip: l10n.eqPresets,
        onSelected: (action) => unawaited(_presetAction(action, preset)),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'duplicate', child: Text(l10n.eqDuplicate)),
          PopupMenuItem(value: 'export', child: Text(l10n.eqExport)),
          if (!preset.builtIn) ...[
            PopupMenuItem(value: 'rename', child: Text(l10n.eqRename)),
            PopupMenuItem(value: 'delete', child: Text(l10n.eqDelete)),
          ],
        ],
      );

  Future<String?> _name(String initial) => showDialog<String>(
    context: context,
    builder: (_) => EqNameDialog(initial: initial),
  );

  Future<void> _saveAs({EqPreset? preset}) async {
    final name = await _name(
      controller.suggestedName(
        preset?.name ??
            ref.read(equalizerProvider).requireValue.selected?.name ??
            l10n.eqCustom,
      ),
    );
    if (name != null && mounted) {
      await controller.saveAs(name, imported: preset, activate: preset == null);
    }
  }

  Future<void> _presetAction(String action, EqPreset preset) async {
    switch (action) {
      case 'rename':
        final name = await _name(preset.name);
        if (name != null && mounted) await controller.rename(preset, name);
      case 'duplicate':
        await _saveAs(preset: preset);
      case 'delete':
        var discardDrafts = false;
        if (ref.read(equalizerProvider).requireValue.hasDraft(preset.id)) {
          final action = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(l10n.eqDelete),
              content: Text(l10n.eqDeleteDraftDescription),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.eqCancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'save'),
                  child: Text(l10n.eqSaveAs),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, 'discard'),
                  child: Text(l10n.eqDiscardDelete),
                ),
              ],
            ),
          );
          if (action == null || !mounted) return;
          if (action == 'save') {
            final name = await _name(controller.suggestedName(preset.name));
            if (name == null ||
                await controller.preserveDraftAs(preset, name) == null) {
              return;
            }
          }
          discardDrafts = true;
        }
        if (await controller.deletePreset(
              preset,
              discardDrafts: discardDrafts,
            ) &&
            mounted) {
          setState(() => _deletedPreset = preset);
        }
      case 'export':
        try {
          final safe = safeFileNameComponent(
            preset.name,
            fallback: l10n.eqImportDefaultName,
          );
          await FilePicker.saveFile(
            fileName: '$safe.navis-eq.json',
            bytes: Uint8List.fromList(
              utf8.encode(
                const JsonEncoder.withIndent('  ').convert(preset.toJson()),
              ),
            ),
            mimeType: 'application/json',
          );
        } on Object {
          if (mounted) _error(l10n.eqExportError);
        }
    }
  }

  Widget _importButton() => PopupMenuButton<String>(
    enabled: !_importing,
    tooltip: l10n.eqImport,
    onSelected: (action) => unawaited(_import(action)),
    itemBuilder: (_) => [
      PopupMenuItem(value: 'file', child: Text(l10n.eqImportFile)),
      PopupMenuItem(value: 'paste', child: Text(l10n.eqImportPaste)),
    ],
    child: IgnorePointer(
      child: OutlinedButton.icon(
        onPressed: _importing ? null : () {},
        icon: const Icon(Icons.file_download_outlined),
        label: Text(l10n.eqImport),
      ),
    ),
  );

  Future<void> _import(String action) async {
    setState(() => _importing = true);
    try {
      EqImportResult? imported;
      if (action == 'autoeq') {
        final preset = await showDialog<EqPreset>(
          context: context,
          builder: (_) => const EqAutoEqDialog(),
        );
        if (preset != null) {
          imported = EqImportResult(
            preset: preset,
            format: EqImportFormat.parametric,
          );
        }
      } else if (action == 'paste') {
        imported = await showDialog<EqImportResult>(
          context: context,
          builder: (_) => const EqPasteDialog(),
        );
      } else {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['txt', 'json'],
        );
        if (file != null) {
          // Some platforms cannot report the size before reading, so the
          // bytes read are checked as well.
          final size = await file.length();
          if (size != null && size > EqImportParser.maximumBytes) {
            throw EqImportException(EqImportErrorCode.tooLarge);
          }
          final bytes = await file.readAsBytes();
          if (bytes.length > EqImportParser.maximumBytes) {
            throw EqImportException(EqImportErrorCode.tooLarge);
          }
          // The contents decide the format and encoding; the file name is
          // only the suggested preset name.
          imported = EqImportParser().parseBytes(
            bytes,
            id: 'preview',
            name: file.name.replaceAll(
              RegExp(r'\.(txt|json)$', caseSensitive: false),
              '',
            ),
          );
        }
      }
      if (imported != null && mounted) {
        final preset = imported.preset;
        final choice = await showDialog<(String, bool)>(
          context: context,
          builder: (_) => EqImportPreviewDialog(
            preset: preset,
            name: controller.suggestedName(preset.name),
            warnings: imported!.warnings,
          ),
        );
        if (choice != null && mounted) {
          await controller.saveAs(
            choice.$1,
            imported: preset,
            activate: choice.$2,
            enable: choice.$2,
          );
        }
      }
    } on EqImportException catch (error) {
      if (mounted) _error(describeEqImportError(l10n, error));
    } on Object catch (error, stackTrace) {
      AppLogger.warning('EQ import failed. $error\n$stackTrace');
      if (mounted) _error(l10n.eqImportError);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _error(String message) =>
      showAppNotice(context, message: message, level: AppNoticeLevel.error);
}
