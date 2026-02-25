import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/domain/smart_queue_state.dart';
import 'package:navis/src/features/player/presentation/smart_queue_notifier.dart';

/// Shows a modal bottom sheet with 4 Smart Queue mood profiles.
///
/// When the user selects a profile the smart queue is activated with
/// [seedSongId] as the starting track.
void showSmartQueueSheet(
  BuildContext context,
  WidgetRef ref, {
  required String seedSongId,
}) {
  final l10n = AppLocalizations.of(context)!;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Theme.of(sheetContext)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Title
              Text(
                l10n.smartQueueTitle,
                style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.smartQueueSubtitle,
                style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              // Profile cards
              ...SmartQueueProfile.values.map(
                (profile) => _SmartQueueProfileCard(
                  profile: profile,
                  l10n: l10n,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    ref
                        .read(smartQueueProvider.notifier)
                        .activate(profile, seedSongId);
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SmartQueueProfileCard extends StatelessWidget {
  const _SmartQueueProfileCard({
    required this.profile,
    required this.l10n,
    required this.onTap,
  });

  final SmartQueueProfile profile;
  final AppLocalizations l10n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: profile.color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: profile.color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    profile.icon,
                    color: profile.color,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _profileTitle(profile),
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _profileDescription(profile),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _profileTitle(SmartQueueProfile profile) {
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

  String _profileDescription(SmartQueueProfile profile) {
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
}
