import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Whether the current queue plays in shuffled order.
final queueShuffleEnabledProvider = Provider<bool>(
  (ref) => ref.watch(
    playerStateProvider.select(
      (snapshot) => snapshot.shuffleMode == AudioServiceShuffleMode.all,
    ),
  ),
);

/// Turns shuffled queue order on or off.
///
/// Shuffle reorders the queue, so it lives in the queue header rather than
/// the transport; the transport keeps Instant Mix in that slot.
class QueueShuffleToggle extends ConsumerWidget {
  const new({super.key});

  static const Key toggleKey = ValueKey<String>('queueShuffleToggle');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = ref.watch(queueShuffleEnabledProvider);
    return IconButton(
      key: toggleKey,
      isSelected: enabled,
      tooltip: enabled ? l10n.nowPlayingShuffle : l10n.nowPlayingShuffleOff,
      icon: const Icon(Icons.shuffle_rounded),
      selectedIcon: Icon(
        Icons.shuffle_on_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      onPressed: () => unawaited(
        ref
            .read(audioHandlerProvider)
            ?.setShuffleMode(
              enabled
                  ? AudioServiceShuffleMode.none
                  : AudioServiceShuffleMode.all,
            ),
      ),
    );
  }
}

/// Marks a Queue button with a small shuffle badge while shuffle is on, so
/// the state stays visible after Shuffle moved into the queue.
class QueueShuffleBadge extends ConsumerWidget {
  const new({required this.child, super.key});

  static const Key badgeKey = ValueKey<String>('queueShuffleBadge');

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    return Badge(
      key: badgeKey,
      isLabelVisible: ref.watch(queueShuffleEnabledProvider),
      backgroundColor: colors.primary,
      padding: const EdgeInsets.all(1),
      offset: const Offset(6, -6),
      label: Icon(Icons.shuffle_rounded, size: 10, color: colors.onPrimary),
      child: child,
    );
  }
}
