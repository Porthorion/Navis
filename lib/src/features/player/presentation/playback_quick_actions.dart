import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/quick_panel.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_quick_panel.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_panel.dart';
import 'package:navis/src/routing/navigation_service.dart';

/// Opens the Speed & Pitch panel from a player control.
///
/// The shared [showQuickPanel] shell pins the title, a live summary and the
/// combined reset, leaving only the controls to scroll.
Future<void> showPlaybackAdjustmentQuickPanel(BuildContext anchorContext) {
  final l10n = AppLocalizations.of(anchorContext)!;
  return showQuickPanel(
    anchorContext,
    panelKey: const ValueKey<String>('playbackAdjustmentQuickPanel'),
    title: l10n.playbackSpeedPitchTitle,
    width: 440,
    maxHeight: 680,
    subtitleBuilder: (_) => const PlaybackAdjustmentSummary(),
    bodyBuilder: (_) => const PlaybackAdjustmentPanel(
      showHeader: false,
      showResetAction: false,
    ),
    footerBuilder: (_) => const _PlaybackAdjustmentFooter(),
  );
}

class _PlaybackAdjustmentFooter extends ConsumerWidget {
  const _PlaybackAdjustmentFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(playbackAdjustmentsProvider).asData?.value;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        key: const ValueKey<String>('playbackAdjustmentQuickReset'),
        onPressed: state == null || state.values.isNone || state.pending
            ? null
            : () => unawaited(
                ref
                    .read(playbackAdjustmentsProvider.notifier)
                    .selectPreset(PlaybackPreset.noneId),
              ),
        icon: const Icon(Icons.restart_alt),
        label: Text(l10n.playbackAdjustmentResetBoth),
      ),
    );
  }
}

/// Opens the compact Equalizer panel: on/off, a read-only response graph and
/// preset selection, with the full page one tap away for editing.
Future<void> showEqualizerQuickPanel(BuildContext anchorContext) {
  final l10n = AppLocalizations.of(anchorContext)!;
  return showQuickPanel(
    anchorContext,
    panelKey: const ValueKey<String>('equalizerQuickPanel'),
    title: l10n.eqTitle,
    width: 380,
    subtitleBuilder: (_) => const EqQuickSummary(),
    headerTrailingBuilder: (_) => const EqEnableSwitch(),
    bodyBuilder: (_) => Consumer(
      builder: (context, ref, _) => EqQuickControls(
        onOpenFullPage: () => NavService.openEqualizer(context, ref),
      ),
    ),
    footerBuilder: (_) => Consumer(
      builder: (context, ref, _) => Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FilledButton.tonalIcon(
          key: const ValueKey<String>('eq-quick-open-page'),
          onPressed: () => NavService.openEqualizer(context, ref),
          icon: const Icon(Icons.tune),
          label: Text(l10n.eqQuickOpen),
        ),
      ),
    ),
  );
}

/// Result of a keyboard speed nudge, used to phrase the confirmation notice.
enum PlaybackSpeedNudgeResult { changed, minimumReached, maximumReached }

/// Steps speed by [hundredths] or, when null, resets it to 1.00×. Pitch and
/// the follow-speed setting are kept, and the change is persisted at once.
Future<PlaybackSpeedNudgeResult?> nudgePlaybackSpeed(
  WidgetRef ref, {
  int? hundredths,
}) async {
  final values = ref.read(playbackAdjustmentsProvider).asData?.value.values;
  if (values == null) return null;
  final range = ref
      .read(playbackAdjustmentCapabilitiesProvider)
      .speedRange(values);
  final target = hundredths == null
      ? 1.0
      : stepAdjustment(values.speed, hundredths);
  final next = range.constrain(target);
  if (next == values.speed) {
    if (hundredths == null) return PlaybackSpeedNudgeResult.changed;
    return hundredths > 0
        ? PlaybackSpeedNudgeResult.maximumReached
        : PlaybackSpeedNudgeResult.minimumReached;
  }
  final controller = ref.read(playbackAdjustmentsProvider.notifier);
  final applied = await controller.setValues(values.copyWith(speed: next));
  await controller.flush();
  return applied ? PlaybackSpeedNudgeResult.changed : null;
}

/// Player control that shows the current speed and opens Speed & Pitch.
///
/// At normal settings it is a plain speed icon. A changed speed replaces the
/// icon with the multiplier (for example `1.25×`); a pitch-only change tints
/// the icon. The glyph slot has a fixed width so transport rows never shift.
class PlaybackSpeedQuickButton extends ConsumerWidget {
  const PlaybackSpeedQuickButton({
    this.enabled = true,
    this.disabledTooltip,
    this.style,
    this.iconSize,
    this.visualDensity,
    this.dense = false,
    super.key,
  });

  final bool enabled;
  final String? disabledTooltip;
  final ButtonStyle? style;
  final double? iconSize;
  final VisualDensity? visualDensity;

  /// Narrow transport rows use a smaller glyph slot and padding.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final values = ref.watch(
      playbackAdjustmentsProvider.select((state) => state.asData?.value.values),
    );
    final size = iconSize ?? IconTheme.of(context).size ?? 24;
    final active = values != null && !values.isNone;
    final speedChanged = values != null && (values.speed - 1).abs() > 1e-10;
    final tooltip = !enabled && disabledTooltip != null
        ? disabledTooltip!
        : values == null
        ? l10n.playbackSpeedPitchTitle
        : l10n.playbackQuickAdjustmentsTooltip(
            formatPlaybackAdjustments(l10n, values),
          );
    final foreground = enabled && active ? colors.primary : null;
    return IconButton(
      tooltip: tooltip,
      style: quickActionDenseStyle(style, dense: dense),
      iconSize: size,
      visualDensity: visualDensity,
      onPressed: enabled
          ? () => unawaited(showPlaybackAdjustmentQuickPanel(context))
          : null,
      icon: quickActionGlyphSlot(
        dense: dense,
        size,
        speedChanged
            ? FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  l10n.playbackSpeedMultiplierValue(
                    formatCompactAdjustmentNumber(values.speed),
                  ),
                  key: const ValueKey<String>('playbackSpeedQuickLabel'),
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: foreground,
                  ),
                ),
              )
            : Icon(Icons.speed, size: size, color: foreground),
      ),
    );
  }
}

/// Fixed-width glyph area shared by the player quick buttons.
///
/// The Speed button swaps its icon for a label such as `1.25×`, so both
/// quick buttons reserve the same slot; flanking the transport with equal
/// widths keeps Play exactly centred.
Widget quickActionGlyphSlot(
  double size,
  Widget child, {
  bool dense = false,
}) => SizedBox(
  width: size + (dense ? 4 : 12),
  height: size,
  child: Center(child: child),
);

/// Tighter padding for [dense] quick buttons on narrow transport rows.
ButtonStyle? quickActionDenseStyle(ButtonStyle? style, {required bool dense}) =>
    dense
    ? (style ?? const ButtonStyle()).merge(
        IconButton.styleFrom(padding: const EdgeInsets.all(4)),
      )
    : style;

/// Location of the full Equalizer page.
const equalizerRouteLocation = '/settings/equalizer';

/// Player control for the equalizer.
///
/// Opens the compact Equalizer panel. While the full page is showing it
/// becomes a selected "Close Equalizer" toggle that returns the person to
/// where they opened it from. Hidden when the active audio backend has no
/// equalizer, so transport rows never carry a permanently dead button; the
/// Settings entry still explains why the equalizer is unavailable.
class EqualizerQuickButton extends ConsumerWidget {
  const EqualizerQuickButton({
    this.enabled = true,
    this.disabledTooltip,
    this.style,
    this.iconSize,
    this.visualDensity,
    this.placeholderWhenUnsupported = false,
    this.dense = false,
    super.key,
  });

  final bool enabled;
  final String? disabledTooltip;
  final ButtonStyle? style;
  final double? iconSize;
  final VisualDensity? visualDensity;

  /// Keeps an invisible slot of the same size when the backend has no EQ, so
  /// a symmetric transport row stays centred.
  final bool placeholderWhenUnsupported;

  /// Narrow transport rows use a smaller glyph slot and padding.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(eqCapabilitiesProvider).supported) {
      if (!placeholderWhenUnsupported) return const SizedBox.shrink();
      final size = iconSize ?? IconTheme.of(context).size ?? 24;
      return Visibility(
        key: const ValueKey<String>('equalizerQuickPlaceholder'),
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: IconButton(
          style: quickActionDenseStyle(style, dense: dense),
          iconSize: size,
          visualDensity: visualDensity,
          onPressed: null,
          icon: quickActionGlyphSlot(
            size,
            const SizedBox.shrink(),
            dense: dense,
          ),
        ),
      );
    }
    final router = GoRouter.maybeOf(context);
    if (router == null) return _button(context, ref, onPage: false);
    return ListenableBuilder(
      listenable: router.routerDelegate,
      builder: (context, _) => _button(
        context,
        ref,
        onPage: router.state.uri.path == equalizerRouteLocation,
      ),
    );
  }

  Widget _button(BuildContext context, WidgetRef ref, {required bool onPage}) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final size = iconSize ?? IconTheme.of(context).size ?? 24;
    final state = ref.watch(equalizerProvider).asData?.value;
    final eqOn = state?.configuration.enabled ?? false;
    final tooltip = !enabled && disabledTooltip != null
        ? disabledTooltip!
        : onPage
        ? l10n.eqQuickClose
        : eqOn
        ? l10n.playbackQuickEqualizerTooltip(state!.displayName(l10n.eqCustom))
        : l10n.playbackQuickEqualizerOff;
    return IconButton(
      tooltip: tooltip,
      isSelected: onPage,
      style: onPage
          ? (quickActionDenseStyle(style, dense: dense) ?? const ButtonStyle())
                .merge(
                  IconButton.styleFrom(
                    backgroundColor: colors.secondaryContainer,
                    foregroundColor: colors.onSecondaryContainer,
                  ),
                )
          : quickActionDenseStyle(style, dense: dense),
      iconSize: size,
      visualDensity: visualDensity,
      onPressed: !enabled
          ? null
          : onPage
          ? () => unawaited(NavService.closeEqualizer(context, ref))
          : () => unawaited(showEqualizerQuickPanel(context)),
      icon: quickActionGlyphSlot(
        dense: dense,
        size,
        Icon(
          Icons.equalizer,
          size: size,
          color: enabled && eqOn && !onPage ? colors.primary : null,
        ),
      ),
    );
  }
}
