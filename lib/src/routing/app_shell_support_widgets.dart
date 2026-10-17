part of 'app_shell.dart';

/// Show the battery optimisation prompt.
///
/// The sheet takes its background from the ambient `bottomSheetTheme` instead
/// of an explicit `backgroundColor`: a colour read from the opener's theme is
/// frozen when the route is pushed, so a live theme switch left the sheet on
/// its old surface while its text followed the new theme.
Future<void> showBatteryOptimizationSheet(
  BuildContext context, {
  required Future<void> Function() onOpenSettings,
  Future<void> Function()? onSnooze,
}) async {
  final openedSettings = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      return _BatteryOptimizationSheet(
        onOpenSettings: () {
          Navigator.of(sheetContext).pop(true);
          unawaited(onOpenSettings());
        },
      );
    },
  );
  if (openedSettings != true) await onSnooze?.call();
}

class _BatteryOptimizationSheet extends StatelessWidget {
  const new({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 8, 20, bottomInset + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.12),
              borderRadius: NavisShapeData.of(context).lgAll,
            ),
            child: Icon(
              Icons.battery_saver_outlined,
              color: colors.primary,
              size: 28,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            l10n.batteryOptimizationPromptTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.batteryOptimizationPromptBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: NavisShapeData.of(context).lgAll,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.sync_outlined,
                  color: colors.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.batteryOptimizationPromptRecommendation,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.batteryOptimizationPromptLaterAction),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.open_in_new),
                  label: Text(l10n.batteryOptimizationPromptOpenSettingsAction),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Hides the bottom navigation bar while the player panel is up.
///
/// The scaffold paints the bar above the body, where the sheet lives, but the
/// panel covers the bar's whole strip from the first pixel of its travel (it
/// is as wide as the screen and reaches the bottom edge). So while the sheet
/// is anywhere above collapsed the bar is not hit-testable (the panel takes
/// the taps) and its semantics are excluded, so screen readers cannot reach
/// it under the panel.
///
/// Visually the bar follows the sheet's soft ends: over the first
/// [ExpandablePlayerSheet.edgeFade] of the travel it slides down out of sight
/// and fades, and it slides back up the same way as the panel lands, instead
/// of cutting in after the collapse.
///
/// Only paint and composite change: the bar keeps its layout size, so the page
/// behind it is not laid out again while the sheet animates.
class _BottomNavReveal extends StatelessWidget {
  const new({
    required this.progress,
    required this.enabled,
    required this.child,
  });

  /// Player sheet progress, 0 collapsed to 1 expanded.
  final ValueNotifier<double> progress;

  /// False when there is no player, so the bar always stays visible.
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      // The bar keeps its own layer, so its pixels are reused every frame.
      child: RepaintBoundary(child: child),
      builder: (context, value, bar) {
        final covered = enabled && value > 0;
        final hidden = enabled
            ? (value / ExpandablePlayerSheet.edgeFade).clamp(0.0, 1.0)
            : 0.0;
        return IgnorePointer(
          ignoring: covered,
          child: ExcludeSemantics(
            excluding: covered,
            child: Opacity(
              opacity: 1 - hidden,
              child: FractionalTranslation(
                translation: Offset(0, hidden),
                child: bar,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Lets the body run behind the bottom navigation bar (`Scaffold.extendBody`)
/// while pages see the same insets as when the body ended above the bar.
///
/// The scaffold reports the bar's height as bottom padding. This scope lifts
/// it out of [MediaQuery] and offers it as [_BottomNavInset] instead, for the
/// page area to keep clear of the bar and for the player sheet to stop above
/// it.
class _BottomNavInsetScope extends StatelessWidget {
  const new({required this.enabled, required this.child});

  /// False when the shell has no bottom navigation bar.
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _BottomNavInset(
      inset: enabled ? MediaQuery.paddingOf(context).bottom : 0,
      child: MediaQuery.removePadding(
        context: context,
        removeBottom: enabled,
        child: child,
      ),
    );
  }
}

/// Height of the bottom navigation bar the body extends behind.
class _BottomNavInset extends InheritedWidget {
  const new({required this.inset, required super.child});

  final double inset;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_BottomNavInset>()?.inset ?? 0;

  @override
  bool updateShouldNotify(_BottomNavInset oldWidget) =>
      inset != oldWidget.inset;
}

/// Keeps [child] clear of the bottom navigation bar the body extends behind.
class _BottomNavInsetPadding extends StatelessWidget {
  const new({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: _BottomNavInset.of(context)),
      child: child,
    );
  }
}
