import 'package:flutter/material.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

class GroupListeningActiveSessionIndicator extends StatelessWidget {
  const GroupListeningActiveSessionIndicator({
    required this.state,
    required this.onTap,
    super.key,
  });

  final GroupListeningSessionState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final room = state.room;
    if (room == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hostStyle = state.snapshotRequired || !state.connection.isConnected
        ? _IndicatorStyle(
            background: scheme.secondaryContainer,
            foreground: scheme.onSecondaryContainer,
            icon: Icons.sync_problem_outlined,
          )
        : _IndicatorStyle(
            background: scheme.primaryContainer,
            foreground: scheme.onPrimaryContainer,
            icon: room.self.role == GroupListeningMemberRole.host
                ? Icons.headset_mic_outlined
                : Icons.people_alt_outlined,
          );

    final title = room.self.role == GroupListeningMemberRole.host
        ? 'Listen Together • Hosting'
        : 'Listen Together • Listening';
    final subtitle = <String>[
      _connectionLabel(state),
      if (state.snapshotRequired) 'Snapshot required' else 'In sync',
      '${room.members.length} in room',
    ].join(' • ');

    return Semantics(
      button: true,
      label: '$title. $subtitle.',
      child: Material(
        key: const ValueKey('groupListeningShellIndicator'),
        color: hostStyle.background,
        borderRadius: BorderRadius.circular(20),
        elevation: 2,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(hostStyle.icon, color: hostStyle.foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: hostStyle.foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hostStyle.foreground.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, color: hostStyle.foreground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IndicatorStyle {
  const _IndicatorStyle({
    required this.background,
    required this.foreground,
    required this.icon,
  });

  final Color background;
  final Color foreground;
  final IconData icon;
}

String _connectionLabel(GroupListeningSessionState state) {
  switch (state.connection.status) {
    case GroupListeningConnectionStatus.connected:
      return 'Connected';
    case GroupListeningConnectionStatus.connecting:
      return 'Connecting';
    case GroupListeningConnectionStatus.reconnecting:
      return 'Reconnecting';
    case GroupListeningConnectionStatus.disconnected:
      return state.status == GroupListeningSessionStatus.error
          ? 'Needs attention'
          : 'Disconnected';
  }
}
