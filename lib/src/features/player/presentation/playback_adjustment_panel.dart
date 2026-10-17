import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/preset_picker.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';

String formatAdjustmentNumber(
  double value, {
  bool signed = true,
  bool approximate = true,
}) {
  final rounded = roundAdjustment(value);
  final number = (rounded == 0 ? 0.0 : rounded).toStringAsFixed(2);
  final sign = signed && rounded > 0 ? '+' : '';
  final prefix = approximate && !isHundredth(value) ? '≈' : '';
  return '$prefix$sign$number';
}

String formatPlaybackAdjustments(
  AppLocalizations l10n,
  PlaybackAdjustments values,
) =>
    '${l10n.playbackSpeedMultiplierValue(formatAdjustmentNumber(values.speed, signed: false))} · ${l10n.playbackPitchSemitonesValue(formatAdjustmentNumber(values.pitchSemitones, approximate: !values.lockPitchToSpeed))}${values.lockPitchToSpeed ? ' · ${l10n.playbackPitchLock}' : ''}';

class PlaybackAdjustmentSummary extends ConsumerWidget {
  const new({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final values = ref.watch(playbackAdjustmentsProvider).asData?.value.values;
    return Text(
      values == null
          ? '…'
          : formatPlaybackAdjustments(AppLocalizations.of(context)!, values),
    );
  }
}

/// Common speeds offered as one-tap choices, filtered by backend limits.
/// Symmetric around 1× so the normal speed sits in the middle of the row.
const playbackSpeedQuickPicks = <double>[0.5, 0.75, 1, 1.25, 1.5];

/// Formats a quick-pick speed without trailing zeros (for example `1.5`).
String formatCompactAdjustmentNumber(double value) {
  final fixed = roundAdjustment(value).toStringAsFixed(2);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

class PlaybackAdjustmentPanel extends ConsumerStatefulWidget {
  const new({
    this.onClose,
    this.showHeader = true,
    this.showResetAction = true,
    super.key,
  });

  /// When provided, the title row gains a close button that invokes this
  /// callback.
  final VoidCallback? onClose;

  /// Quick panels pin their own title, summary and reset action outside the
  /// scrolling area, so they hide these.
  final bool showHeader;
  final bool showResetAction;

  @override
  ConsumerState<PlaybackAdjustmentPanel> createState() =>
      _PlaybackAdjustmentPanelState();
}

class _PlaybackAdjustmentPanelState
    extends ConsumerState<PlaybackAdjustmentPanel> {
  late PlaybackAdjustmentController _controller;
  int _interactionToken = 0;

  void _cancelRulers() => setState(() => _interactionToken++);

  @override
  void initState() {
    super.initState();
    _controller = ref.read(playbackAdjustmentsProvider.notifier);
  }

  void _flush() => unawaited(_controller.flush());

  /// Steps [keyName] by [hundredths] from the latest state so hold-to-repeat
  /// never reuses a value captured by an earlier build.
  bool _step(String keyName, int hundredths) {
    final state = ref.read(playbackAdjustmentsProvider).asData?.value;
    if (state == null) return false;
    final values = state.values;
    final capabilities = ref.read(playbackAdjustmentCapabilitiesProvider);
    final speed = keyName == 'speed';
    final current = speed ? values.speed : values.pitchSemitones;
    final range = speed
        ? capabilities.speedRange(values)
        : capabilities.pitchRange(values);
    final next = range.constrain(stepAdjustment(current, hundredths));
    if (hundredths < 0 ? next >= current : next <= current) return false;
    _cancelRulers();
    unawaited(
      _controller.setValues(
        speed
            ? values.copyWith(speed: next)
            : values.copyWith(pitchSemitones: next),
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final settings = ref.watch(playbackAdjustmentsProvider);
    _controller = ref.read(playbackAdjustmentsProvider.notifier);
    final capabilities = ref.watch(playbackAdjustmentCapabilitiesProvider);
    return settings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.playbackAdjustmentLoadFailure),
          TextButton(
            onPressed: () => ref.invalidate(playbackAdjustmentsProvider),
            child: Text(l10n.playbackAdjustmentRetry),
          ),
        ],
      ),
      data: (data) {
        final pitchSupported = capabilities.pitchSupported;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeader) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.playbackSpeedPitchTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (widget.onClose != null)
                    IconButton(
                      key: const ValueKey('playbackAdjustmentClose'),
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            _presetPicker(data, capabilities),
            const Divider(height: 24),
            _control(
              keyName: 'speed',
              label: l10n.playbackSettingsPlaybackSpeedLabel,
              value: data.values.speed,
              valueLabel: l10n.playbackSpeedMultiplierValue(
                formatAdjustmentNumber(data.values.speed, signed: false),
              ),
              range: capabilities.speedRange(data.values),
              resetValue: 1,
              buttonHundredths: 10,
              onChanged: (value) => unawaited(
                _controller.setValues(
                  ref
                      .read(playbackAdjustmentsProvider)
                      .requireValue
                      .values
                      .copyWith(speed: value),
                ),
              ),
            ),
            if (pitchSupported) ...[
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                key: const ValueKey('playback-pitch-lock'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.playbackPitchLock),
                subtitle: Text(l10n.playbackPitchLockSubtitle),
                value: data.values.lockPitchToSpeed,
                onChanged: (value) {
                  _cancelRulers();
                  unawaited(_controller.setPitchLock(enabled: value));
                },
              ),
              const SizedBox(height: 8),
              _control(
                keyName: 'pitch',
                label: l10n.playbackPitchLabel,
                value: data.values.pitchSemitones,
                valueLabel: l10n.playbackPitchSemitonesValue(
                  formatAdjustmentNumber(
                    data.values.pitchSemitones,
                    approximate: !data.values.lockPitchToSpeed,
                  ),
                ),
                range: capabilities.pitchRange(data.values),
                enabled: !data.values.lockPitchToSpeed,
                linked: data.values.lockPitchToSpeed,
                onChanged: (value) => unawaited(
                  _controller.setValues(
                    ref
                        .read(playbackAdjustmentsProvider)
                        .requireValue
                        .values
                        .copyWith(pitchSemitones: value),
                  ),
                ),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.playbackPitchUnavailable,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            if (data.failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(switch (data.failure!) {
                  PlaybackAdjustmentFailure.unsupported =>
                    l10n.playbackAdjustmentUnsupported,
                  PlaybackAdjustmentFailure.lockUnsupported =>
                    l10n.playbackPitchLockUnsupportedRange,
                  PlaybackAdjustmentFailure.application =>
                    l10n.playbackAdjustmentApplyFailure,
                  PlaybackAdjustmentFailure.persistence =>
                    l10n.playbackAdjustmentSaveFailure,
                  PlaybackAdjustmentFailure.presetMissing =>
                    l10n.playbackPresetDeleteFailure,
                  PlaybackAdjustmentFailure.name =>
                    l10n.playbackPresetNameInvalid,
                }, style: TextStyle(color: theme.colorScheme.error)),
              ),
            if (data.failure == PlaybackAdjustmentFailure.persistence)
              TextButton(
                onPressed: _flush,
                child: Text(l10n.playbackAdjustmentRetry),
              ),
            if (widget.showResetAction) ...[
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () {
                    _cancelRulers();
                    unawaited(_controller.selectPreset(PlaybackPreset.noneId));
                  },
                  icon: const Icon(Icons.restart_alt),
                  label: Text(l10n.playbackAdjustmentResetBoth),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// Preset dropdown plus an actions menu. A dropdown stays compact however
  /// many presets exist; managing them acts on the current preset (or the one
  /// being edited) instead of a separate picker.
  Widget _presetPicker(
    PlaybackAdjustmentState data,
    PlaybackAdjustmentCapabilities capabilities,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final selected = data.selectedPresetId;
    final origin = data.presets
        .where((p) => p.id == data.originPresetId)
        .firstOrNull;
    final target =
        data.presets.where((p) => p.id == selected).firstOrNull ?? origin;
    return PresetPicker(
      keyPrefix: 'playbackPreset',
      icon: Icons.speed,
      enabled: !data.pending,
      selectedId: selected,
      entries: [
        PresetPickerEntry(
          id: PlaybackPreset.noneId,
          label: l10n.playbackPresetNone,
          icon: Icons.restart_alt,
        ),
        for (final preset in data.presets)
          PresetPickerEntry(
            id: preset.id,
            label: preset.name,
            enabled: capabilities.supports(preset.values),
            disabledReason: l10n.playbackPresetUnsupported,
          ),
      ],
      updateId: origin?.id,
      manageId: target?.id,
      labels: PresetPickerLabels(
        picker: l10n.playbackPresetLabel,
        custom: l10n.playbackPresetCustom,
        actions: l10n.playbackPresetActions,
        saveNew: l10n.playbackPresetSaveNew,
        update: l10n.playbackPresetUpdateNamed,
        rename: l10n.playbackPresetRenameNamed,
        delete: l10n.playbackPresetDeleteNamed,
        deleteConfirm: l10n.playbackPresetDeleteConfirm,
        renameTitle: l10n.playbackPresetRename,
        nameField: l10n.playbackPresetName,
        cancel: l10n.playbackAdjustmentCancel,
        save: l10n.playbackAdjustmentSave,
        deleteAction: l10n.playbackPresetDelete,
        discard: l10n.eqDiscardChanges,
        discardConfirm: l10n.presetDiscardConfirm,
      ),
      onSelect: (id) {
        _cancelRulers();
        return _controller.selectPreset(id);
      },
      onSaveNew: (name) async =>
          await _controller.savePreset(name) ? null : _nameError(),
      onUpdate: (id) => _controller.savePreset(
        data.presets.firstWhere((p) => p.id == id).name,
        updateId: id,
      ),
      onDiscard: (id) {
        _cancelRulers();
        return _controller.selectPreset(id);
      },
      onRename: (id, name) async =>
          await _controller.renamePreset(id, name) ? null : _nameError(),
      onDelete: (id) async {
        if (await _controller.deletePreset(id) || !mounted) return;
        showAppNotice(
          context,
          message: l10n.playbackPresetDeleteFailure,
          level: AppNoticeLevel.error,
        );
      },
    );
  }

  /// Why a preset name was refused: the save failing, or the name itself.
  String _nameError() {
    final l10n = AppLocalizations.of(context)!;
    return ref.read(playbackAdjustmentsProvider).asData?.value.failure ==
            PlaybackAdjustmentFailure.persistence
        ? l10n.playbackAdjustmentSaveFailure
        : l10n.playbackPresetNameInvalid;
  }

  Widget _control({
    required String keyName,
    required String label,
    required double value,
    required String valueLabel,
    required ValueChanged<double> onChanged,
    required AdjustmentRange range,
    double resetValue = 0,
    int buttonHundredths = 100,
    bool enabled = true,
    bool linked = false,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final speed = keyName == 'speed';
    String formatted(double v) => speed
        ? l10n.playbackSpeedMultiplierValue(
            formatAdjustmentNumber(v, signed: false),
          )
        : l10n.playbackPitchSemitonesValue(formatAdjustmentNumber(v));
    final stepLabel = speed
        ? l10n.playbackSpeedMultiplierValue(
            formatAdjustmentNumber(buttonHundredths / 100, signed: false),
          )
        : l10n.playbackPitchSemitonesValue(
            formatCompactAdjustmentNumber(buttonHundredths / 100),
          );
    final minimum = range.minimum;
    final maximum = range.maximum;
    final lower = range.constrain(stepAdjustment(value, -buttonHundredths));
    final upper = range.constrain(stepAdjustment(value, buttonHundredths));
    final atMinimum = minimum != null && value <= minimum + 1e-10;
    final atMaximum = maximum != null && value >= maximum - 1e-10;
    final quickPicks = speed
        ? playbackSpeedQuickPicks.where(range.contains).toList()
        : const <double>[];
    final showReset =
        !speed &&
        enabled &&
        range.contains(resetValue) &&
        (value - resetValue).abs() > 1e-10;
    Widget stepper({
      required String keySuffix,
      required IconData icon,
      required String tooltip,
      required bool canStep,
      required int hundredths,
    }) {
      // Linked pitch has no usable steppers; an invisible stand-in keeps its
      // ruler the same width as the speed ruler above it.
      if (linked) {
        return Visibility(
          visible: false,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: IconButton(onPressed: null, icon: Icon(icon)),
        );
      }
      return RulerStepButton(
        key: ValueKey('adjustment-$keyName-$keySuffix'),
        icon: icon,
        tooltip: tooltip,
        enabled: enabled && canStep,
        onStep: () => _step(keyName, hundredths),
        onEnd: _flush,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(label, style: theme.textTheme.titleSmall)),
                if (linked) ...[
                  const SizedBox(width: 6),
                  // Pitch is driven by speed: say so on the heading rather
                  // than greying out the values.
                  Tooltip(
                    message: l10n.playbackPitchFollowsSpeed,
                    child: Icon(
                      Icons.link_rounded,
                      key: ValueKey('adjustment-$keyName-linked'),
                      size: 18,
                      color: theme.colorScheme.primary,
                      semanticLabel: l10n.playbackPitchFollowsSpeed,
                    ),
                  ),
                ],
                // Speed resets through its 1× chip. Pitch has no chips, so
                // once changed it offers Reset where the link icon sits
                // while linked.
                if (showReset) ...[
                  const SizedBox(width: 4),
                  // The icon matches "Reset Speed & Pitch" and keeps the
                  // button from reading as part of the heading.
                  TextButton.icon(
                    key: ValueKey('adjustment-$keyName-reset'),
                    onPressed: () {
                      _cancelRulers();
                      onChanged(resetValue);
                      _flush();
                    },
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: Text(l10n.playbackAdjustmentReset),
                  ),
                ],
              ],
            ),
            TextButton(
              key: ValueKey('adjustment-$keyName-value'),
              style: TextButton.styleFrom(
                disabledForegroundColor: theme.colorScheme.onSurface,
                // Fixed-width digits keep the readout still while dragging.
                textStyle: theme.textTheme.titleLarge?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              onPressed: enabled
                  ? () => _enterValue(label, value, onChanged, isSpeed: speed)
                  : null,
              child: Text(valueLabel),
            ),
          ],
        ),
        if (quickPicks.isNotEmpty) ...[
          LayoutBuilder(
            builder: (context, constraints) {
              Widget chip(double pick) => ChoiceChip(
                key: ValueKey(
                  'adjustment-$keyName-chip-${formatCompactAdjustmentNumber(pick)}',
                ),
                label: Text(
                  l10n.playbackSpeedMultiplierValue(
                    formatCompactAdjustmentNumber(pick),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                showCheckmark: false,
                selected: (value - pick).abs() < 1e-10,
                onSelected: enabled
                    ? (_) {
                        if ((value - pick).abs() < 1e-10) return;
                        _cancelRulers();
                        onChanged(pick);
                        _flush();
                      }
                    : null,
              );
              // Equal-width slots keep 1× exactly centred and the row
              // centred in its panel. Large text falls back to a centred
              // wrap rather than squeezing labels.
              final slotWidth = (constraints.maxWidth / quickPicks.length)
                  .clamp(0.0, 88.0);
              final minimumSlot = MediaQuery.textScalerOf(context).scale(60);
              if (slotWidth < minimumSlot) {
                return Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  runSpacing: 8,
                  children: [for (final pick in quickPicks) chip(pick)],
                );
              }
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final pick in quickPicks)
                    SizedBox(
                      width: slotWidth,
                      child: Center(child: chip(pick)),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
        ],
        // Steppers sit at the ends of the scale they move. The painter puts
        // lower values on the left in every locale, so the row stays LTR.
        Row(
          textDirection: TextDirection.ltr,
          children: [
            stepper(
              keySuffix: 'minus',
              icon: Icons.remove,
              tooltip: l10n.playbackAdjustmentDecreaseBy(stepLabel),
              canStep: lower < value,
              hundredths: -buttonHundredths,
            ),
            Expanded(
              child: AdjustmentRuler(
                key: ValueKey('adjustment-$keyName-ruler'),
                value: value,
                label: label,
                valueLabel: valueLabel,
                onChanged: onChanged,
                onChangeEnd: _flush,
                range: range,
                resetValue: resetValue,
                interactionToken: _interactionToken,
                enabled: enabled,
                readOnly: linked,
              ),
            ),
            stepper(
              keySuffix: 'plus',
              icon: Icons.add,
              tooltip: l10n.playbackAdjustmentIncreaseBy(stepLabel),
              canStep: upper > value,
              hundredths: buttonHundredths,
            ),
          ],
        ),
        if (enabled && (atMinimum || atMaximum)) ...[
          Text(
            speed
                ? (atMinimum
                      ? l10n.playbackSpeedMinimumReached
                      : l10n.playbackSpeedMaximumReached)
                : (atMinimum
                      ? l10n.playbackPitchMinimumReached
                      : l10n.playbackPitchMaximumReached),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          Text(
            minimum != null && maximum != null
                ? l10n.playbackAdjustmentRange(
                    formatted(minimum),
                    formatted(maximum),
                  )
                : minimum != null
                ? l10n.playbackAdjustmentMinimum(formatted(minimum))
                : l10n.playbackAdjustmentMaximum(formatted(maximum!)),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Future<void> _enterValue(
    String label,
    double value,
    ValueChanged<double> onChanged, {
    required bool isSpeed,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => TextEntryDialog(
        title: label,
        initialText: value.toStringAsFixed(2),
        numeric: true,
        fieldKey: const ValueKey('adjustmentExactInput'),
        confirmLabel: l10n.playbackAdjustmentApply,
        cancelLabel: l10n.playbackAdjustmentCancel,
        onSubmit: (raw) async {
          if (!RegExp(r'^[+-]?(?:[0-9]+(?:[.,][0-9]{0,2})?|[.,][0-9]{1,2})$')
              .hasMatch(raw.trim())) {
            return l10n.playbackAdjustmentPrecision;
          }
          final parsed = double.tryParse(raw.trim().replaceAll(',', '.'));
          if (parsed == null || !parsed.isFinite) {
            return l10n.playbackAdjustmentInvalidNumber;
          }
          final current = ref
              .read(playbackAdjustmentsProvider)
              .requireValue
              .values;
          if (!isSpeed && current.lockPitchToSpeed) {
            return l10n.playbackPitchFollowsSpeed;
          }
          final candidate = isSpeed
              ? current.copyWith(speed: parsed)
              : current.copyWith(pitchSemitones: parsed);
          return ref
                  .read(playbackAdjustmentCapabilitiesProvider)
                  .supports(candidate)
              ? null
              : l10n.playbackAdjustmentUnsupported;
        },
      ),
    );
    if (result != null && mounted) {
      _cancelRulers();
      onChanged(
        (double.parse(result.trim().replaceAll(',', '.')) * 100).round() / 100,
      );
      _flush();
    }
  }

  @override
  void dispose() {
    _flush();
    super.dispose();
  }
}
