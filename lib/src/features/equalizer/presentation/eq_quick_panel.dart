import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/quick_panel.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_editor.dart';
import 'package:navis/src/routing/navigation_service.dart';

/// Whether the requested EQ is currently being applied, waiting for audio,
/// running, or bypassed. Shared by the full page and the quick surfaces.
String eqApplicationStatusLabel(EqState value, AppLocalizations l10n) {
  final application = value.application;
  return value.pending
      ? l10n.eqApplying
      : application?.pending == true ||
            (value.configuration.enabled && application?.sampleRate == null)
      ? l10n.eqPending
      : application?.applied.enabled == true
      ? l10n.eqApplied
      : l10n.eqBypassed;
}

/// `Preset · Status`, e.g. "Bass boost · Applied".
String eqQuickSummary(EqState value, AppLocalizations l10n) =>
    '${value.displayName(l10n.eqCustom)} · ${eqApplicationStatusLabel(value, l10n)}';

/// Live one-line summary for quick panel headers.
class EqQuickSummary extends ConsumerWidget {
  const EqQuickSummary({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(equalizerProvider).asData?.value;
    return Text(
      value == null
          ? '…'
          : eqQuickSummary(value, AppLocalizations.of(context)!),
    );
  }
}

/// Master on/off switch for the equalizer.
class EqEnableSwitch extends ConsumerWidget {
  const EqEnableSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final value = ref.watch(equalizerProvider).asData?.value;
    return Semantics(
      label: l10n.eqEnable,
      child: Switch.adaptive(
        key: const ValueKey<String>('eq-quick-enable'),
        value: value?.configuration.enabled ?? false,
        onChanged: value == null || value.pending
            ? null
            : (enabled) => unawaited(
                ref
                    .read(equalizerProvider.notifier)
                    .setEnabled(enabled: enabled),
              ),
      ),
    );
  }
}

enum EqQuickLayout {
  /// Popover/sheet body: chips wrap onto several rows.
  panel,

  /// Settings-sheet card: one horizontally scrolling chip row.
  inline,
}

/// Compact equalizer controls: a read-only response graph and one-tap preset
/// selection. Editing curves stays on the full Equalizer page, which the
/// graph opens through [onOpenFullPage].
class EqQuickControls extends ConsumerWidget {
  const EqQuickControls({
    this.layout = EqQuickLayout.panel,
    this.onOpenFullPage,
    super.key,
  });

  final EqQuickLayout layout;
  final VoidCallback? onOpenFullPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final state = ref.watch(equalizerProvider);
    final value = state.asData?.value;
    if (value == null) {
      return SizedBox(
        height: 96,
        child: Center(
          child: state.hasError
              ? Text(l10n.eqUnavailable)
              : const CircularProgressIndicator(),
        ),
      );
    }
    final controller = ref.read(equalizerProvider.notifier);
    final enabled = value.configuration.enabled;
    final inline = layout == EqQuickLayout.inline;
    final sampleRate =
        value.application?.responseSampleRate ??
        value.application?.sampleRate ??
        48000;
    final graph = Semantics(
      label: l10n.eqResponse,
      value: eqQuickSummary(value, l10n),
      button: onOpenFullPage != null,
      hint: onOpenFullPage == null ? null : l10n.eqQuickEditHint,
      child: Tooltip(
        message: onOpenFullPage == null ? '' : l10n.eqQuickEditHint,
        child: GestureDetector(
          key: const ValueKey<String>('eq-quick-graph'),
          behavior: HitTestBehavior.opaque,
          onTap: onOpenFullPage,
          child: AnimatedOpacity(
            key: const ValueKey<String>('eq-quick-graph-opacity'),
            opacity: enabled ? 1 : 0.4,
            duration: const Duration(milliseconds: 180),
            child: SizedBox(
              height: inline ? 88 : 104,
              child: ExcludeSemantics(
                child: EqGraphEditor(
                  configuration: value.configuration,
                  selectedBand: null,
                  sampleRate: sampleRate,
                  enabled: false,
                  readOnly: true,
                  compact: true,
                  readOnlyMinimumLimit: 12,
                  onSelect: (_) {},
                  onBegin: () {},
                  onChanged: (_) {},
                  onCommit: () {},
                  onCancel: () {},
                  onPreampInput: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    Future<void> select(EqPreset? preset) async {
      if (preset == null) {
        if (value.selectedPresetId != null) await controller.selectCustom();
      } else if (value.selectedPresetId != preset.id) {
        await controller.selectPreset(preset, enable: true);
        return;
      }
      // Picking a sound means "I want to hear it": turn the EQ on.
      if (!ref.read(equalizerProvider).requireValue.configuration.enabled) {
        await controller.setEnabled(enabled: true);
      }
    }

    final customDraft = value.hasDraft(eqCustomWorkspace);
    final chips = <Widget>[
      if (value.selectedPresetId == null || customDraft)
        _PresetChip(
          id: eqCustomWorkspace,
          label: '${l10n.eqCustom}${customDraft ? '*' : ''}',
          selected: value.selectedPresetId == null,
          enabled: !value.pending,
          onSelected: () => unawaited(select(null)),
        ),
      for (final preset in [...value.presets, ...EqPreset.builtIns])
        _PresetChip(
          id: preset.id,
          label: '${preset.name}${value.hasDraft(preset.id) ? '*' : ''}',
          avatar: preset.source != null
              ? const Icon(Icons.headphones_outlined, size: 18)
              : null,
          selected: value.selectedPresetId == preset.id,
          enabled: !value.pending,
          onSelected: () => unawaited(select(preset)),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value.failure != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    value.failure!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(controller.retry()),
                  child: Text(l10n.commonRetry),
                ),
              ],
            ),
          ),
        graph,
        SizedBox(height: inline ? 10 : 14),
        if (!inline) ...[
          Text(l10n.eqPresets, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ] else
          _InlineChipRow(children: chips),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.id,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onSelected,
    this.avatar,
  });

  final String id;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      key: ValueKey<String>('eq-quick-preset-$id'),
      avatar: avatar,
      showCheckmark: false,
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      selected: selected,
      onSelected: enabled ? (_) => onSelected() : null,
    );
  }
}

/// A single scrolling row of chips that brings the selected chip into view.
class _InlineChipRow extends StatefulWidget {
  const _InlineChipRow({required this.children});

  final List<Widget> children;

  @override
  State<_InlineChipRow> createState() => _InlineChipRowState();
}

class _InlineChipRowState extends State<_InlineChipRow> {
  final _scroll = ScrollController();
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Reveal the selected chip within this row only; ensureVisible would
      // also scroll any enclosing sheet or list.
      final target = _selectedKey.currentContext?.findRenderObject();
      if (!mounted || target is! RenderBox || !_scroll.hasClients) return;
      final viewport = RenderAbstractViewport.maybeOf(target);
      if (viewport == null) return;
      final position = _scroll.position;
      _scroll.jumpTo(
        viewport
            .getOffsetToReveal(target, 0.5)
            .offset
            .clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScrollEdgeFade(
      controller: _scroll,
      axis: Axis.horizontal,
      child: SingleChildScrollView(
        key: const ValueKey<String>('eq-quick-chip-row'),
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final chip in widget.children)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: chip is _PresetChip && chip.selected
                    ? KeyedSubtree(key: _selectedKey, child: chip)
                    : chip,
              ),
          ],
        ),
      ),
    );
  }
}

/// Inline equalizer card for player settings: title, switch, graph, presets
/// and a link to the full page.
class EqQuickCard extends ConsumerWidget {
  const EqQuickCard({this.onOpenFullPage, super.key});

  /// Overrides how the full page opens (for example after closing a sheet).
  final VoidCallback? onOpenFullPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final open = onOpenFullPage ?? () => NavService.openEqualizer(context, ref);
    return Material(
      key: const ValueKey<String>('eq-quick-card'),
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.equalizer),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.eqTitle, style: theme.textTheme.titleMedium),
                      DefaultTextStyle.merge(
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: const EqQuickSummary(),
                      ),
                    ],
                  ),
                ),
                const EqEnableSwitch(),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: EqQuickControls(
                layout: EqQuickLayout.inline,
                onOpenFullPage: open,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: const ValueKey<String>('eq-quick-open-page'),
                onPressed: open,
                icon: const Icon(Icons.tune),
                label: Text(l10n.eqQuickOpen),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
