import 'package:flutter/material.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_track_resolution_service.dart';

class ListenTogetherStatusChip extends StatelessWidget {
  const ListenTogetherStatusChip({
    required this.icon,
    required this.label,
    super.key,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(avatar: Icon(icon, size: 18), label: Text(label));
  }
}

class ListenTogetherMetadataRow extends StatelessWidget {
  const ListenTogetherMetadataRow({
    required this.label,
    required this.value,
    super.key,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class ListenTogetherMemberBadge extends StatelessWidget {
  const ListenTogetherMemberBadge({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Chip(
        visualDensity: VisualDensity.compact,
        label: Text(label),
      ),
    );
  }
}

class ListenTogetherFailureCard extends StatelessWidget {
  const ListenTogetherFailureCard({
    required this.failure,
    required this.message,
    required this.onDismiss,
    super.key,
  });

  final GroupListeningErrorState failure;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Room issue',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
                if (failure.retryable ||
                    failure.retryAfter != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    failure.retryAfter == null
                        ? 'You can retry this room action now.'
                        : 'Try again in ${failure.retryAfter!.inSeconds}s.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            color: scheme.onErrorContainer,
            icon: const Icon(Icons.close),
            tooltip: 'Dismiss room issue',
          ),
        ],
      ),
    );
  }
}

class ListenTogetherQueueResolutionTile extends StatelessWidget {
  const ListenTogetherQueueResolutionTile({
    required this.entry,
    required this.readiness,
    super.key,
  });

  final GroupListeningQueueEntry entry;
  final GroupListeningTrackResolutionReadiness readiness;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (readiness) {
      GroupListeningTrackResolutionReadiness.ready =>
        Icons.check_circle_outline,
      GroupListeningTrackResolutionReadiness.resolving =>
        Icons.hourglass_top_outlined,
      GroupListeningTrackResolutionReadiness.unavailable => Icons.error_outline,
    };
    final color = switch (readiness) {
      GroupListeningTrackResolutionReadiness.ready => theme.colorScheme.primary,
      GroupListeningTrackResolutionReadiness.resolving =>
        theme.colorScheme.tertiary,
      GroupListeningTrackResolutionReadiness.unavailable =>
        theme.colorScheme.error,
    };
    final title = entry.title ?? entry.songId;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color, size: 18),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}
