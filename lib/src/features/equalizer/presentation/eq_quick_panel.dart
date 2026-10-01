import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_editor.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_tokens.dart';

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
  const new({super.key});

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
  const new({super.key});

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
  const new({
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
              height: inline ? 136 : 176,
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
    DropdownMenuEntry<String> entry(String id, String label, IconData icon) =>
        DropdownMenuEntry<String>(
          value: id,
          label: label,
          leadingIcon: Icon(icon, size: 20),
        );
    final entries = <DropdownMenuEntry<String>>[
      if (value.selectedPresetId == null || customDraft)
        entry(
          eqCustomWorkspace,
          '${l10n.eqCustom}${customDraft ? '*' : ''}',
          Icons.edit_outlined,
        ),
      for (final preset in value.presets)
        entry(
          preset.id,
          '${preset.name}${value.hasDraft(preset.id) ? '*' : ''}',
          preset.source != null ? Icons.headphones_outlined : Icons.tune,
        ),
      for (final preset in EqPreset.builtIns)
        entry(
          preset.id,
          '${preset.name}${value.hasDraft(preset.id) ? '*' : ''}',
          Icons.graphic_eq,
        ),
    ];
    final selected = value.selectedPresetId ?? eqCustomWorkspace;
    final selectedEntry = entries.where((e) => e.value == selected).firstOrNull;
    // Keyed by the shown selection so a change made elsewhere (for example on
    // the full page) refreshes the field text.
    final presetPicker = KeyedSubtree(
      key: ValueKey<String>('eq-quick-preset-${selectedEntry?.label}'),
      child: DropdownMenu<String>(
        key: const ValueKey<String>('eq-quick-preset'),
        enabled: !value.pending,
        expandedInsets: EdgeInsets.zero,
        requestFocusOnTap: false,
        menuHeight: 320,
        label: Text(l10n.eqPresets),
        leadingIcon: selectedEntry?.leadingIcon,
        initialSelection: selectedEntry?.value,
        dropdownMenuEntries: entries,
        onSelected: (id) {
          if (id == null) return;
          final preset = value.allPresets
              .where((candidate) => candidate.id == id)
              .firstOrNull;
          unawaited(select(id == eqCustomWorkspace ? null : preset));
        },
      ),
    );

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
        SizedBox(height: inline ? 12 : 16),
        presetPicker,
      ],
    );
  }
}

/// Inline equalizer card for player settings: title, switch, graph, presets
/// and a link to the full page.
class EqQuickCard extends ConsumerWidget {
  const new({this.onOpenFullPage, super.key});

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
      borderRadius: NavisRadius.lgAll,
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
