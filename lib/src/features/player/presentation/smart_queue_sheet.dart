import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/domain/smart_queue_state.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_notifier.dart';

/// Shows a bottom sheet that lets the user choose between Smart Queue modes
/// and the classic Instant Mix mode.
void showMixModeSheet(
  BuildContext context, {
  required String seedSongId,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return Consumer(
        builder: (context, ref, _) {
          final l10n = AppLocalizations.of(sheetContext)!;
          final smartQueue = ref.watch(smartQueueProvider);
          final instantMix = ref.watch(instantMixProvider);

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        sheetContext,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Text(
                    l10n.nowPlayingMixTitle,
                    style: Theme.of(sheetContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.nowPlayingMixSubtitle,
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(
                          color: Theme.of(
                            sheetContext,
                          ).colorScheme.onSurfaceVariant,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ...SmartQueueProfile.values.map(
                    (profile) => _QueueModeCard(
                      icon: profile.icon,
                      color: profile.color,
                      title: _smartQueueProfileTitle(l10n, profile),
                      description: _smartQueueProfileDescription(l10n, profile),
                      active:
                          smartQueue.active && smartQueue.profile == profile,
                      loading:
                          smartQueue.refilling &&
                          smartQueue.active &&
                          smartQueue.profile == profile,
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        ref.read(instantMixProvider.notifier).deactivate();

                        if (smartQueue.active &&
                            smartQueue.profile == profile) {
                          ref.read(smartQueueProvider.notifier).deactivate();
                          return;
                        }

                        ref.read(smartQueueProvider.notifier).deactivate();
                        await ref
                            .read(smartQueueProvider.notifier)
                            .activate(profile, seedSongId);
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  _QueueModeCard(
                    icon: Icons.explore_outlined,
                    color: Theme.of(sheetContext).colorScheme.primary,
                    title: l10n.nowPlayingInstantMixLabel,
                    description: l10n.nowPlayingInstantMixDescription,
                    active: instantMix.active,
                    loading: instantMix.refilling && instantMix.active,
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      ref.read(smartQueueProvider.notifier).deactivate();

                      if (instantMix.active) {
                        ref.read(instantMixProvider.notifier).deactivate();
                        return;
                      }

                      await ref
                          .read(instantMixProvider.notifier)
                          .activate(seedSongId);
                    },
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// Backwards-compatible wrapper for any older call sites.
void showSmartQueueSheet(
  BuildContext context,
  WidgetRef ref, {
  required String seedSongId,
}) {
  showMixModeSheet(context, seedSongId: seedSongId);
}

class _QueueModeCard extends StatelessWidget {
  const _QueueModeCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
    required this.active,
    required this.loading,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String description;
  final bool active;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: color.withValues(alpha: active ? 0.18 : 0.1),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: active ? 0.3 : 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: loading
                      ? Padding(
                          padding: const EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: color,
                          ),
                        )
                      : Icon(icon, color: color, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  active ? Icons.check_circle : Icons.chevron_right,
                  color: active ? color : colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _smartQueueProfileTitle(
  AppLocalizations l10n,
  SmartQueueProfile profile,
) {
  switch (profile) {
    case SmartQueueProfile.steadyVibes:
      return l10n.smartQueueSteadyVibes;
    case SmartQueueProfile.discoveryMix:
      return l10n.smartQueueDiscoveryMix;
    case SmartQueueProfile.deepDive:
      return l10n.smartQueueDeepDive;
    case SmartQueueProfile.energyFlow:
      return l10n.smartQueueEnergyFlow;
  }
}

String _smartQueueProfileDescription(
  AppLocalizations l10n,
  SmartQueueProfile profile,
) {
  switch (profile) {
    case SmartQueueProfile.steadyVibes:
      return l10n.smartQueueSteadyVibesDesc;
    case SmartQueueProfile.discoveryMix:
      return l10n.smartQueueDiscoveryMixDesc;
    case SmartQueueProfile.deepDive:
      return l10n.smartQueueDeepDiveDesc;
    case SmartQueueProfile.energyFlow:
      return l10n.smartQueueEnergyFlowDesc;
  }
}
