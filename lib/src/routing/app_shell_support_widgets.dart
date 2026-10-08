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
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      return _BatteryOptimizationSheet(
        onOpenSettings: () {
          Navigator.of(sheetContext).pop();
          unawaited(onOpenSettings());
        },
      );
    },
  );
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
              borderRadius: NavisRadius.lgAll,
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
              borderRadius: NavisRadius.lgAll,
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

class _BottomNavReveal extends StatelessWidget {
  const new({required this.reveal, required this.child});

  final double reveal;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final clamped = reveal.clamp(0.0, 1.0);
    if (clamped <= 0.001) {
      return const SizedBox.shrink();
    }

    final opacity = Curves.easeOut.transform(clamped);
    final slideOffset = (1 - clamped) * 24;

    return IgnorePointer(
      ignoring: clamped < 0.98,
      child: ClipRect(
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: clamped,
          child: Transform.translate(
            offset: Offset(0, slideOffset),
            child: Opacity(opacity: opacity, child: child),
          ),
        ),
      ),
    );
  }
}
