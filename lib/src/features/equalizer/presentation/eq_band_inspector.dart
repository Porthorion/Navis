import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_tooltip.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_editor.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_geometry.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_painter.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Parameter identifiers shared by value tiles, exact entry and diagnostics.
abstract final class EqParameter {
  static const frequency = 'frequency';
  static const gain = 'gain';
  static const q = 'q';
  static const preamp = 'preamp';

  static String label(AppLocalizations l10n, String parameter) =>
      switch (parameter) {
        frequency => l10n.eqFrequency,
        gain => l10n.eqGain,
        q => l10n.eqQ,
        _ => l10n.eqPreamp,
      };

  static String unit(String parameter) => switch (parameter) {
    frequency => 'Hz',
    q => '',
    _ => 'dB',
  };

  static int decimals(String parameter) => parameter == q ? 3 : 2;

  static (double, double) range(String parameter) => switch (parameter) {
    frequency => (20, 20000),
    q => (.1, 20),
    preamp => (-60, 24),
    _ => (-24, 24),
  };

  /// Readouts trim zeros and show at most two (Q: three) decimals.
  static String readout(String parameter, double value) =>
      parameter == gain || parameter == preamp
      ? eqSignedGain(value)
      : eqNumber(value, decimals: decimals(parameter));
}

String eqModeShortLabel(AppLocalizations l10n, EqMode mode) => switch (mode) {
  EqMode.simple => l10n.eqSimpleShort,
  EqMode.tenBand => l10n.eqTenBandShort,
  EqMode.advanced => l10n.eqAdvanced,
  EqMode.importedFixed => l10n.eqImportedShort,
};

/// Every band in authored order; the only band selector besides the graph.
class EqBandStrip extends StatefulWidget {
  const new({
    required this.filters,
    required this.selected,
    required this.onSelect,
    this.enabled = true,
    this.wrap = false,
    super.key,
  });

  final List<EqFilter> filters;
  final int? selected;
  final ValueChanged<int> onSelect;
  final bool enabled;

  /// Wide inspectors show every band; phones scroll horizontally.
  final bool wrap;

  @override
  State<EqBandStrip> createState() => _EqBandStripState();
}

class _EqBandStripState extends State<EqBandStrip> {
  final _scroll = ScrollController();
  final _chips = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(EqBandStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected ||
        oldWidget.filters.length != widget.filters.length) {
      _reveal();
    }
  }

  void _reveal() {
    if (widget.wrap) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chip = _chips[widget.selected]?.currentContext;
      if (!mounted || chip == null) return;
      Scrollable.ensureVisible(
        chip,
        alignment: .5,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _chip(BuildContext context, int i) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final filter = widget.filters[i];
    final selected = i == widget.selected;
    final foreground = selected ? colors.onPrimary : colors.onSurface;
    return KeyedSubtree(
      key: ValueKey('eq-band-chip-$i'),
      child: ChoiceChip(
        key: _chips.putIfAbsent(i, GlobalKey.new),
        showCheckmark: false,
        selected: selected,
        selectedColor: colors.primary,
        side: BorderSide(
          color: selected
              ? colors.primary
              : filter.enabled
              ? colors.outlineVariant
              : colors.outlineVariant.withValues(alpha: .5),
        ),
        visualDensity: VisualDensity.compact,
        onSelected: widget.enabled ? (_) => widget.onSelect(i) : null,
        label: Semantics(
          label:
              '${l10n.eqBand(i + 1)}, ${eqNumber(filter.frequencyHz)} Hz, ${eqBandSummary(l10n, filter)}',
          child: ExcludeSemantics(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${i + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: ' · ${eqShortFrequency(filter.frequencyHz)}'),
                ],
              ),
              style: TextStyle(
                color: filter.enabled
                    ? foreground
                    : foreground.withValues(alpha: .6),
                decoration: filter.enabled ? null : TextDecoration.lineThrough,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final chips = [
      for (var i = 0; i < widget.filters.length; i++) _chip(context, i),
    ];
    return Semantics(
      container: true,
      label: l10n.eqBands,
      child: widget.wrap
          ? Wrap(spacing: 6, runSpacing: 6, children: chips)
          // At most 32 chips: building them eagerly keeps every chip
          // addressable for ensureVisible and keyboard traversal.
          : Listener(
              onPointerSignal: _wheel,
              child: Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  key: const ValueKey('eq-band-strip'),
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      for (var i = 0; i < chips.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        chips[i],
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  /// Lets a vertical mouse wheel scroll the horizontal strip on desktop.
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final position = _scroll.position;
      _scroll.jumpTo(
        (position.pixels + delta).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }
}

/// A labelled value that opens exact entry, or explains why it is fixed.
class EqParameterTile extends StatelessWidget {
  const new({
    required this.parameter,
    required this.value,
    this.onPressed,
    this.fixed = false,
    this.notApplicable = false,
    super.key,
  });

  final String parameter;
  final double value;
  final VoidCallback? onPressed;
  final bool fixed;
  final bool notApplicable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final editable = onPressed != null;
    final unit = EqParameter.unit(parameter);
    final hint = editable
        ? l10n.eqEnterExact
        : fixed
        ? l10n.eqFixedInMode
        : null;
    final button = TextButton(
      key: ValueKey('eq-input-$parameter'),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: colors.surfaceContainerHigh,
        foregroundColor: colors.onSurface,
        disabledBackgroundColor: colors.surfaceContainer,
        disabledForegroundColor: colors.onSurfaceVariant,
        alignment: AlignmentDirectional.centerStart,
        padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 10, 8),
        minimumSize: const Size(0, 56),
        shape: RoundedRectangleBorder(borderRadius: NavisRadius.mdAll),
      ),
      child: Semantics(
        hint: hint,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    EqParameter.label(l10n, parameter),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                if (editable)
                  Icon(
                    Icons.edit_outlined,
                    size: 14,
                    color: colors.onSurfaceVariant,
                  )
                else if (fixed)
                  Icon(Icons.lock_outline, size: 14, color: colors.outline),
              ],
            ),
            const SizedBox(height: 2),
            if (notApplicable)
              Text(
                l10n.eqNotApplicable,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              )
            else
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: EqParameter.readout(parameter, value),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: editable ? colors.onSurface : null,
                      ),
                    ),
                    if (unit.isNotEmpty)
                      TextSpan(
                        text: ' $unit',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    if (fixed)
                      TextSpan(
                        text: ' · ${l10n.eqFixed}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.outline,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
    return hint == null
        ? button
        : NavisTooltip(
            message: hint,
            excludeFromSemantics: true,
            child: button,
          );
  }
}

/// Logarithmic Q control with plain-language direction labels.
class EqQControl extends StatelessWidget {
  const new({
    required this.q,
    required this.onBegin,
    required this.onChanged,
    required this.onEnd,
    required this.onCancel,
    this.enabled = true,
    super.key,
  });

  final double q;
  final VoidCallback onBegin;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;
  final VoidCallback onCancel;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final style = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Row(
      children: [
        Text(l10n.eqWider, style: style),
        Expanded(
          child: Listener(
            onPointerCancel: enabled ? (_) => onCancel() : null,
            child: Slider(
              key: const ValueKey('eq-graph-q'),
              value: EqGraphGeometry.qPosition(q).clamp(0, 1),
              label: 'Q ${eqNumber(q, decimals: 3)}',
              semanticFormatterCallback: (value) =>
                  '${l10n.eqBandwidth}, Q ${eqNumber(EqGraphGeometry.qAt(value), decimals: 3)}',
              onChangeStart: enabled ? (_) => onBegin() : null,
              onChanged: enabled
                  ? (value) => onChanged(EqGraphGeometry.qAt(value))
                  : null,
              onChangeEnd: enabled ? (_) => onEnd() : null,
            ),
          ),
        ),
        Text(l10n.eqNarrower, style: style),
      ],
    );
  }
}

/// The selected band's parameters and band-level actions.
class EqBandInspector extends StatelessWidget {
  const new({
    required this.configuration,
    required this.selected,
    required this.onSelect,
    required this.onEdit,
    required this.onUpdateBand,
    required this.onAddBand,
    required this.onDeleteBand,
    required this.onEditAdvanced,
    required this.onQBegin,
    required this.onQChanged,
    required this.onQEnd,
    required this.onQCancel,
    this.showPreamp = false,
    this.wide = false,
    super.key,
  });

  final EqConfiguration configuration;
  final int? selected;
  final ValueChanged<int> onSelect;
  final ValueChanged<String> onEdit;
  final void Function(int index, EqFilter filter) onUpdateBand;
  final VoidCallback onAddBand;
  final VoidCallback onDeleteBand;
  final VoidCallback onEditAdvanced;
  final VoidCallback onQBegin;
  final ValueChanged<double> onQChanged;
  final VoidCallback onQEnd;
  final VoidCallback onQCancel;

  /// Shown only when the graph toolbar (and its preamp control) is hidden.
  final bool showPreamp;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    Widget bandSwitch(EqFilter filter) => _BandSwitch(
      value: filter.enabled,
      onChanged: (enabled) =>
          onUpdateBand(selected!, filter.copyWith(enabled: enabled)),
    );
    return LayoutBuilder(
      builder: (context, constraints) => _controls(
        context,
        // Wrapping every chip only helps when the values stay in view.
        wrapBands:
            wide &&
            configuration.filters.length <= 16 &&
            constraints.maxHeight >= 420,
        bandSwitch: bandSwitch,
      ),
    );
  }

  Widget _controls(
    BuildContext context, {
    required bool wrapBands,
    required Widget Function(EqFilter filter) bandSwitch,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final advanced = configuration.mode == EqMode.advanced;
    final filter = selected == null ? null : configuration.filters[selected!];
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return ListView(
      key: const ValueKey('eq-band-controls'),
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        if (configuration.filters.isNotEmpty)
          EqBandStrip(
            filters: configuration.filters,
            selected: selected,
            onSelect: onSelect,
            wrap: wrapBands,
          ),
        const SizedBox(height: 8),
        if (filter != null) ...[
          LayoutBuilder(
            builder: (context, constraints) {
              final tiles = [
                EqParameterTile(
                  parameter: EqParameter.frequency,
                  value: filter.frequencyHz,
                  fixed: !advanced,
                  onPressed: advanced
                      ? () => onEdit(EqParameter.frequency)
                      : null,
                ),
                EqParameterTile(
                  parameter: EqParameter.gain,
                  value: filter.gainDb,
                  notApplicable: !filter.usesGain,
                  onPressed: filter.usesGain
                      ? () => onEdit(EqParameter.gain)
                      : null,
                ),
                EqParameterTile(
                  parameter: EqParameter.q,
                  value: filter.q,
                  fixed: !advanced,
                  onPressed: advanced ? () => onEdit(EqParameter.q) : null,
                ),
              ];
              // Frequency needs the most digits, so it gets a wider tile.
              const flexes = [4, 3, 3];
              final row =
                  (constraints.maxWidth - 16) * .3 >= 84 * scale.clamp(1, 2);
              return row
                  ? Row(
                      children: [
                        for (var i = 0; i < tiles.length; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(flex: flexes[i], child: tiles[i]),
                        ],
                      ],
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < tiles.length; i++) ...[
                          if (i > 0) const SizedBox(height: 8),
                          SizedBox(width: double.infinity, child: tiles[i]),
                        ],
                      ],
                    );
            },
          ),
          if (advanced) ...[
            const SizedBox(height: 4),
            EqQControl(
              q: filter.q,
              onBegin: onQBegin,
              onChanged: onQChanged,
              onEnd: onQEnd,
              onCancel: onQCancel,
            ),
          ],
          const SizedBox(height: 4),
          if (advanced)
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<EqFilterType>(
                    key: ValueKey('eq-type-$selected-${filter.type}'),
                    initialValue: filter.type,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.eqType,
                      isDense: true,
                    ),
                    items: [
                      for (final type in EqFilterType.values)
                        DropdownMenuItem(
                          value: type,
                          child: Text(
                            eqFilterTypeLabel(l10n, type),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (type) {
                      if (type != null) {
                        onUpdateBand(selected!, filter.copyWith(type: type));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(child: bandSwitch(filter)),
              ],
            )
          else
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                bandSwitch(filter),
                TextButton.icon(
                  key: const ValueKey('eq-edit-advanced'),
                  onPressed: onEditAdvanced,
                  icon: const Icon(Icons.tune),
                  label: Text(l10n.eqEditAdvanced),
                ),
              ],
            ),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(l10n.eqNoBands, style: theme.textTheme.bodyMedium),
          ),
        if (advanced) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('eq-add-band'),
                onPressed:
                    configuration.filters.length <
                        EqConfiguration.maximumFilters
                    ? onAddBand
                    : null,
                icon: const Icon(Icons.add),
                label: Text(l10n.eqAddBand),
              ),
              if (filter != null)
                TextButton.icon(
                  key: const ValueKey('eq-delete-band'),
                  onPressed: onDeleteBand,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.eqDeleteBand),
                ),
            ],
          ),
        ],
        if (showPreamp) ...[
          const SizedBox(height: 12),
          EqParameterTile(
            parameter: EqParameter.preamp,
            value: configuration.preampDb,
            onPressed: () => onEdit(EqParameter.preamp),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          l10n.eqGraphDescription,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _BandSwitch extends StatelessWidget {
  const new({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MergeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(l10n.eqBandEnabled, maxLines: 2)),
          const SizedBox(width: 8),
          Switch.adaptive(
            key: const ValueKey('eq-band-enabled'),
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Inline exact entry. The page keeps ownership of text, preview and commit.
class EqNumberEditor extends StatelessWidget {
  const new({
    required this.parameter,
    required this.bandNumber,
    required this.controller,
    required this.focusNode,
    required this.error,
    required this.onChanged,
    required this.onSubmitted,
    required this.onCancel,
    required this.onNudge,
    this.dense = false,
    super.key,
  });

  final String parameter;
  final int? bandNumber;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? error;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final VoidCallback onCancel;
  final ValueChanged<int> onNudge;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final (minimum, maximum) = EqParameter.range(parameter);
    final unit = EqParameter.unit(parameter);
    final label = EqParameter.label(l10n, parameter);
    String bound(double value) =>
        unit.isEmpty ? eqNumber(value) : '${eqNumber(value)} $unit';
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): _CancelNumberIntent(),
      },
      child: Actions(
        actions: {
          _CancelNumberIntent: CallbackAction<_CancelNumberIntent>(
            onInvoke: (_) {
              onCancel();
              return null;
            },
          ),
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey('eq-edit-$parameter'),
                    controller: controller,
                    focusNode: focusNode,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    textInputAction: TextInputAction.done,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    decoration: InputDecoration(
                      labelText: bandNumber == null
                          ? label
                          : l10n.eqEditingValue(
                              l10n.eqBand(bandNumber!),
                              label,
                            ),
                      suffixText: unit,
                      helperText: l10n.eqRange(bound(minimum), bound(maximum)),
                      helperMaxLines: 2,
                      errorText: error,
                      errorMaxLines: 3,
                    ),
                    onChanged: onChanged,
                    onFieldSubmitted: (_) => onSubmitted(),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: IconButton.filledTonal(
                    tooltip: l10n.eqDecrease,
                    onPressed: () => onNudge(-1),
                    icon: const Icon(Icons.remove),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: IconButton.filledTonal(
                    tooltip: l10n.eqIncrease,
                    onPressed: () => onNudge(1),
                    icon: const Icon(Icons.add),
                  ),
                ),
              ],
            ),
            if (!dense) ...[
              const SizedBox(height: 8),
              Text(
                l10n.eqNumericPreview,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CancelNumberIntent extends Intent {
  const new();
}

/// Undo/Redo and draft actions, or Cancel/Done while entering a number.
class EqActionBar extends StatelessWidget {
  const new({
    required this.editingNumber,
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
    required this.saveLabel,
    required this.onSave,
    required this.onDiscard,
    required this.onCancelNumber,
    required this.onDoneNumber,
    super.key,
  });

  final bool editingNumber;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  /// Null hides Save; [onSave] null keeps it visible but unavailable.
  final String? saveLabel;
  final VoidCallback? onSave;

  /// Null hides Discard.
  final VoidCallback? onDiscard;
  final VoidCallback onCancelNumber;
  final VoidCallback onDoneNumber;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (editingNumber) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            key: const ValueKey('eq-number-cancel'),
            onPressed: onCancelNumber,
            child: Text(l10n.eqCancel),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const ValueKey('eq-number-done'),
            onPressed: onDoneNumber,
            child: Text(l10n.eqDone),
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1, 2);
        final labelled = constraints.maxWidth >= 300 * scale;
        return Row(
          children: [
            IconButton(
              key: const ValueKey('eq-undo'),
              tooltip: l10n.eqUndo,
              onPressed: canUndo ? onUndo : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              key: const ValueKey('eq-redo'),
              tooltip: l10n.eqRedo,
              onPressed: canRedo ? onRedo : null,
              icon: const Icon(Icons.redo),
            ),
            const SizedBox(width: 8),
            // Labels shrink with ellipsis before anything can overflow.
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onDiscard != null && labelled)
                    Flexible(
                      child: TextButton(
                        key: const ValueKey('eq-discard'),
                        onPressed: onDiscard,
                        child: Text(
                          l10n.eqDiscard,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                  else if (onDiscard != null)
                    IconButton(
                      key: const ValueKey('eq-discard'),
                      tooltip: l10n.eqDiscardChanges,
                      onPressed: onDiscard,
                      icon: const Icon(Icons.restore),
                    ),
                  if (saveLabel != null) const SizedBox(width: 4),
                  if (saveLabel != null && labelled)
                    Flexible(
                      flex: 2,
                      child: FilledButton.icon(
                        key: const ValueKey('eq-save'),
                        onPressed: onSave,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(
                          saveLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                  else if (saveLabel != null)
                    IconButton.filled(
                      key: const ValueKey('eq-save'),
                      tooltip: saveLabel,
                      onPressed: onSave,
                      icon: const Icon(Icons.save_outlined),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Simple, 10-band and Advanced, plus Imported when that layout exists.
class EqModeSelector extends StatelessWidget {
  const new({
    required this.mode,
    required this.modes,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final EqMode mode;
  final List<EqMode> modes;
  final ValueChanged<EqMode> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final fits = constraints.maxWidth >= modes.length * 88 * scale;
        if (fits) {
          return SegmentedButton<EqMode>(
            key: const ValueKey('eq-mode-selector'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              for (final value in modes)
                ButtonSegment(
                  value: value,
                  label: Text(
                    eqModeShortLabel(l10n, value),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  tooltip: eqModeLabel(l10n, value),
                ),
            ],
            selected: {mode},
            onSelectionChanged: enabled
                ? (selection) {
                    if (selection.single != mode) onChanged(selection.single);
                  }
                : null,
          );
        }
        return DropdownButtonFormField<EqMode>(
          key: ValueKey('eq-mode-$mode'),
          initialValue: mode,
          isExpanded: true,
          decoration: InputDecoration(labelText: l10n.eqMode, isDense: true),
          items: [
            for (final value in modes)
              DropdownMenuItem(
                value: value,
                child: Text(
                  eqModeLabel(l10n, value),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: enabled
              ? (value) {
                  if (value != null && value != mode) onChanged(value);
                }
              : null,
        );
      },
    );
  }
}

String eqModeLabel(AppLocalizations l10n, EqMode mode) => switch (mode) {
  EqMode.simple => l10n.eqSimple,
  EqMode.tenBand => l10n.eqTenBand,
  EqMode.advanced => l10n.eqAdvanced,
  EqMode.importedFixed => l10n.eqImportedFixed,
};
