import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_provider.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_screen.dart';

enum GroupListeningSessionButtonVariant { standard, filledTonal }

/// A compact icon button that shows the current group listening state and
/// opens the Listen Together sheet when tapped.
class GroupListeningSessionButton extends ConsumerWidget {
  const GroupListeningSessionButton({
    super.key,
    this.variant = GroupListeningSessionButtonVariant.standard,
    this.constraints,
  });

  final GroupListeningSessionButtonVariant variant;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      groupListeningSettingsProvider.select((settings) => settings.enabled),
    );
    if (!enabled) {
      return const SizedBox.shrink();
    }

    final session = ref.watch(groupListeningSessionControllerProvider);
    final room = session.room;
    final connectedCount = room?.activeMemberCount ?? 0;
    final roomCount = room?.members.length ?? 0;
    final syncHealth = session.syncHealth;

    final IconData icon;
    final Color? color;
    final String tooltip;

    if (room == null) {
      icon = Icons.people_alt_outlined;
      color = null;
      tooltip = 'Listen Together';
    } else if (syncHealth == GroupListeningSyncHealth.catchingUp) {
      icon = Icons.sync_outlined;
      color = Theme.of(context).colorScheme.tertiary;
      tooltip = 'Listen Together · Catching up…';
    } else if (syncHealth == GroupListeningSyncHealth.snapshotRecovery ||
        syncHealth == GroupListeningSyncHealth.degraded ||
        session.snapshotRequired ||
        !session.connection.isConnected) {
      icon = Icons.sync_problem_outlined;
      color = Theme.of(context).colorScheme.error;
      tooltip = 'Listen Together · Needs attention';
    } else if (room.self.role == GroupListeningMemberRole.host) {
      icon = Icons.headset_mic;
      color = Theme.of(context).colorScheme.primary;
      tooltip =
          'Listen Together · Hosting · $connectedCount connected'
          '${roomCount != connectedCount ? ' · $roomCount in room' : ''}';
    } else {
      icon = Icons.people_alt;
      color = Theme.of(context).colorScheme.primary;
      tooltip =
          'Listen Together · $connectedCount connected'
          '${roomCount != connectedCount ? ' · $roomCount in room' : ''}';
    }

    final iconWidget = Badge(
      isLabelVisible: connectedCount > 0,
      label: Text(
        connectedCount > 99 ? '99+' : '$connectedCount',
        key: const ValueKey('groupListeningSessionBadgeLabel'),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Icon(icon, color: color),
          if (room != null)
            Positioned(
              right: -2,
              bottom: -2,
              child: _SyncHealthPill(health: syncHealth),
            ),
        ],
      ),
    );

    switch (variant) {
      case GroupListeningSessionButtonVariant.standard:
        return IconButton(
          key: const ValueKey('groupListeningSessionButton'),
          tooltip: tooltip,
          constraints: constraints,
          icon: iconWidget,
          onPressed: () => showListenTogetherSheet(context),
        );
      case GroupListeningSessionButtonVariant.filledTonal:
        return IconButton.filledTonal(
          key: const ValueKey('groupListeningSessionButton'),
          tooltip: tooltip,
          constraints: constraints,
          icon: iconWidget,
          onPressed: () => showListenTogetherSheet(context),
        );
    }
  }
}

class _SyncHealthPill extends StatelessWidget {
  const _SyncHealthPill({required this.health});

  final GroupListeningSyncHealth health;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (health) {
      case GroupListeningSyncHealth.synced:
        color = const Color(0xFF2E7D32);
      case GroupListeningSyncHealth.catchingUp:
        color = const Color(0xFFED6C02);
      case GroupListeningSyncHealth.snapshotRecovery:
        color = const Color(0xFFED6C02);
      case GroupListeningSyncHealth.degraded:
        color = const Color(0xFFD32F2F);
    }
    return Container(
      key: ValueKey('groupListeningSyncHealthPill-${health.name}'),
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.surface,
          width: 1.5,
        ),
      ),
    );
  }
}
