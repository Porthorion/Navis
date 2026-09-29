import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
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
  const PlaybackAdjustmentSummary({super.key});
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
const playbackSpeedQuickPicks = <double>[0.5, 0.75, 1, 1.25, 1.5, 2];

/// Formats a quick-pick speed without trailing zeros (for example `1.5`).
String formatCompactAdjustmentNumber(double value) {
  final fixed = roundAdjustment(value).toStringAsFixed(2);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

class PlaybackAdjustmentPanel extends ConsumerStatefulWidget {
  const PlaybackAdjustmentPanel({
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
        final selected = data.selectedPresetId;
        final origin = data.presets
            .where((p) => p.id == data.originPresetId)
            .firstOrNull;
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
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Text(l10n.playbackPresetLabel, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (selected == null)
                  ChoiceChip(
                    key: const ValueKey('playbackPreset-custom'),
                    label: Text(l10n.playbackPresetCustom),
                    selected: true,
                    onSelected: (_) {},
                  ),
                _presetChip(
                  id: PlaybackPreset.noneId,
                  name: l10n.playbackPresetNone,
                  selected: selected == PlaybackPreset.noneId,
                  supported: true,
                ),
                for (final preset in data.presets)
                  _presetChip(
                    id: preset.id,
                    name: preset.name,
                    selected: selected == preset.id,
                    supported: capabilities.supports(preset.values),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: data.pending ? null : _saveAsNew,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.playbackPresetSaveNew),
                ),
                if (origin != null)
                  TextButton(
                    onPressed: data.pending
                        ? null
                        : () => unawaited(
                            _controller.savePreset(
                              origin.name,
                              updateId: origin.id,
                            ),
                          ),
                    child: Text(l10n.playbackPresetUpdate),
                  ),
                if (data.presets.isNotEmpty)
                  PopupMenuButton<String>(
                    tooltip: l10n.playbackPresetManage,
                    onSelected: _manage,
                    itemBuilder: (_) => [
                      for (final preset in data.presets)
                        PopupMenuItem(
                          value: preset.id,
                          child: Text(
                            preset.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Text(
                        l10n.playbackPresetManage,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
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
              if (data.values.lockPitchToSpeed)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l10n.playbackPitchFollowsSpeed,
                    style: theme.textTheme.bodySmall,
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
                child: Text(
                  switch (data.failure!) {
                    PlaybackAdjustmentFailure.unsupported =>
                      l10n.playbackAdjustmentUnsupported,
                    PlaybackAdjustmentFailure.lockUnsupported =>
                      l10n.playbackPitchLockUnsupportedRange,
                    PlaybackAdjustmentFailure.application =>
                      l10n.playbackAdjustmentApplyFailure,
                    PlaybackAdjustmentFailure.persistence =>
                      l10n.playbackAdjustmentSaveFailure,
                    PlaybackAdjustmentFailure.name =>
                      l10n.playbackPresetNameInvalid,
                  },
                  style: TextStyle(color: theme.colorScheme.error),
                ),
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

  Widget _presetChip({
    required String id,
    required String name,
    required bool selected,
    required bool supported,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final chip = ChoiceChip(
      key: ValueKey('playbackPreset-$id'),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      selected: selected,
      onSelected: supported
          ? (_) {
              if (selected) return;
              _cancelRulers();
              unawaited(_controller.selectPreset(id));
            }
          : null,
    );
    return supported
        ? chip
        : Tooltip(message: l10n.playbackPresetUnsupported, child: chip);
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(label, style: theme.textTheme.titleSmall),
            TextButton(
              key: ValueKey('adjustment-$keyName-value'),
              style: TextButton.styleFrom(
                disabledForegroundColor: theme.colorScheme.onSurface,
                textStyle: theme.textTheme.titleLarge,
              ),
              onPressed: enabled
                  ? () => _enterValue(label, value, onChanged, isSpeed: speed)
                  : null,
              child: Text(valueLabel),
            ),
          ],
        ),
        if (quickPicks.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final pick in quickPicks)
                ChoiceChip(
                  key: ValueKey(
                    'adjustment-$keyName-chip-${formatCompactAdjustmentNumber(pick)}',
                  ),
                  label: Text(
                    l10n.playbackSpeedMultiplierValue(
                      formatCompactAdjustmentNumber(pick),
                    ),
                  ),
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
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        AdjustmentRuler(
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
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _RepeatingStepButton(
              key: ValueKey('adjustment-$keyName-minus'),
              icon: Icons.remove,
              tooltip: l10n.playbackAdjustmentDecreaseBy(stepLabel),
              enabled: enabled && lower < value,
              onStep: () => _step(keyName, -buttonHundredths),
              onEnd: _flush,
            ),
            TextButton(
              key: ValueKey('adjustment-$keyName-reset'),
              onPressed:
                  enabled && range.contains(resetValue) && value != resetValue
                  ? () {
                      _cancelRulers();
                      onChanged(resetValue);
                      _flush();
                    }
                  : null,
              child: Text(l10n.playbackAdjustmentReset),
            ),
            _RepeatingStepButton(
              key: ValueKey('adjustment-$keyName-plus'),
              icon: Icons.add,
              tooltip: l10n.playbackAdjustmentIncreaseBy(stepLabel),
              enabled: enabled && upper > value,
              onStep: () => _step(keyName, buttonHundredths),
              onEnd: _flush,
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
      builder: (context) => _AdjustmentInputDialog(
        title: label,
        initialText: value.toStringAsFixed(2),
        numeric: true,
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

  Future<void> _saveAsNew() => _nameDialog();

  Future<void> _nameDialog({PlaybackPreset? rename}) async {
    final l10n = AppLocalizations.of(context)!;
    await showDialog<String>(
      context: context,
      builder: (context) => _AdjustmentInputDialog(
        title: rename == null
            ? l10n.playbackPresetSaveNew
            : l10n.playbackPresetRename,
        initialText: rename?.name ?? '',
        numeric: false,
        onSubmit: (raw) async {
          final success = rename == null
              ? await _controller.savePreset(raw)
              : await _controller.renamePreset(rename.id, raw);
          if (success) return null;
          return ref.read(playbackAdjustmentsProvider).asData?.value.failure ==
                  PlaybackAdjustmentFailure.persistence
              ? l10n.playbackAdjustmentSaveFailure
              : l10n.playbackPresetNameInvalid;
        },
      ),
    );
  }

  Future<void> _manage(String id) async {
    final preset = ref
        .read(playbackAdjustmentsProvider)
        .requireValue
        .presets
        .where((p) => p.id == id)
        .firstOrNull;
    if (preset == null) return;
    final l10n = AppLocalizations.of(context)!;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(preset.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('rename'),
            child: Text(l10n.playbackPresetRename),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('delete'),
            child: Text(l10n.playbackPresetDelete),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'rename') await _nameDialog(rename: preset);
    if (action == 'delete') await _controller.deletePreset(id);
  }

  @override
  void dispose() {
    _flush();
    super.dispose();
  }
}

class _AdjustmentInputDialog extends StatefulWidget {
  const _AdjustmentInputDialog({
    required this.title,
    required this.initialText,
    required this.numeric,
    required this.onSubmit,
  });
  final String title;
  final String initialText;
  final bool numeric;
  final Future<String?> Function(String) onSubmit;
  @override
  State<_AdjustmentInputDialog> createState() => _AdjustmentInputDialogState();
}

class _AdjustmentInputDialogState extends State<_AdjustmentInputDialog> {
  late final TextEditingController _input;
  String? _error;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.initialText);
  }

  Future<void> _submit() async {
    setState(() => _saving = true);
    final error = await widget.onSubmit(_input.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(_input.text);
    } else {
      setState(() {
        _error = error;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: ValueKey(
          widget.numeric ? 'adjustmentExactInput' : 'playbackPresetNameInput',
        ),
        controller: _input,
        autofocus: true,
        keyboardType: widget.numeric
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : TextInputType.text,
        decoration: InputDecoration(
          errorText: _error,
          labelText: widget.numeric ? null : l10n.playbackPresetName,
        ),
        onSubmitted: _saving ? null : (_) => unawaited(_submit()),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.playbackAdjustmentCancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(
            widget.numeric
                ? l10n.playbackAdjustmentApply
                : l10n.playbackAdjustmentSave,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }
}

/// An icon stepper that repeats while held and reports when input ends.
class _RepeatingStepButton extends StatefulWidget {
  const _RepeatingStepButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onStep,
    required this.onEnd,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;

  /// Applies one step; returns false once a limit stops further steps.
  final bool Function() onStep;
  final VoidCallback onEnd;

  @override
  State<_RepeatingStepButton> createState() => _RepeatingStepButtonState();
}

class _RepeatingStepButtonState extends State<_RepeatingStepButton> {
  static const _repeatInterval = Duration(milliseconds: 120);
  Timer? _repeat;

  void _startRepeat() {
    if (!widget.onStep()) return;
    _repeat?.cancel();
    _repeat = Timer.periodic(_repeatInterval, (_) {
      if (!mounted || !widget.onStep()) _stopRepeat();
    });
  }

  void _stopRepeat() {
    final wasRepeating = _repeat != null;
    _repeat?.cancel();
    _repeat = null;
    if (wasRepeating) widget.onEnd();
  }

  @override
  void didUpdateWidget(_RepeatingStepButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _stopRepeat();
  }

  @override
  Widget build(BuildContext context) {
    // A manual tooltip keeps hover hints without competing with hold-to-repeat
    // for the long-press gesture.
    return Tooltip(
      message: widget.tooltip,
      triggerMode: TooltipTriggerMode.manual,
      child: GestureDetector(
        onLongPressStart: widget.enabled ? (_) => _startRepeat() : null,
        onLongPressEnd: widget.enabled ? (_) => _stopRepeat() : null,
        onLongPressCancel: widget.enabled ? _stopRepeat : null,
        child: IconButton(
          onPressed: widget.enabled
              ? () {
                  if (widget.onStep()) widget.onEnd();
                }
              : null,
          icon: Icon(widget.icon),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _repeat?.cancel();
    _repeat = null;
    super.dispose();
  }
}
