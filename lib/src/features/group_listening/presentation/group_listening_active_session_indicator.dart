import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_screen.dart';

/// A compact icon button that shows the current group listening state and
/// opens the Listen Together sheet when tapped.
class GroupListeningSessionButton extends ConsumerWidget {
  const GroupListeningSessionButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(groupListeningSessionControllerProvider);
    final room = session.room;

    final IconData icon;
    final Color? color;
    final String tooltip;

    if (room == null) {
      icon = Icons.people_alt_outlined;
      color = null;
      tooltip = 'Listen Together';
    } else if (session.snapshotRequired || !session.connection.isConnected) {
      icon = Icons.sync_problem_outlined;
      color = Theme.of(context).colorScheme.error;
      tooltip = 'Listen Together · Needs attention';
    } else if (room.self.role == GroupListeningMemberRole.host) {
      icon = Icons.headset_mic;
      color = Theme.of(context).colorScheme.primary;
      tooltip = 'Listen Together · Hosting · ${room.members.length} in room';
    } else {
      icon = Icons.people_alt;
      color = Theme.of(context).colorScheme.primary;
      tooltip = 'Listen Together · ${room.members.length} in room';
    }

    return IconButton(
      key: const ValueKey('groupListeningSessionButton'),
      tooltip: tooltip,
      icon: Icon(icon, color: color),
      onPressed: () => showListenTogetherSheet(context),
    );
  }
}

