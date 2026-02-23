import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/providers/app_providers.dart';

final currentQueueSongIdProvider = Provider<String?>((ref) {
  return ref.watch(playerStateProvider).currentSongId;
});

class QueueController extends Notifier<List<String>> {
  @override
  List<String> build() {
    final snapshot = ref.watch(playbackSnapshotProvider).asData?.value;
    final ids = snapshot?.queueSongIds ?? const <String>[];
    return List<String>.unmodifiable(ids);
  }

  Future<void> replace(
    List<String> ids, {
    int startIndex = 0,
    bool autoPlay = true,
  }) async {
    final handler = _requireHandler();
    final normalized = _normalizeSongIds(ids);
    if (normalized.isEmpty) {
      await handler.clearQueue();
      return;
    }
    final normalizedStartIndex = startIndex.clamp(0, normalized.length - 1);
    await handler.replaceQueue(
      normalized,
      startIndex: normalizedStartIndex,
      autoPlay: autoPlay,
    );
  }

  Future<void> add(String id) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final handler = _requireHandler();
    await handler.addToQueue(<String>[normalizedId]);
  }

  Future<void> playNext(String id) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final handler = _requireHandler();
    await handler.playNext(<String>[normalizedId]);
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final handler = _requireHandler();
    await handler.reorderQueue(oldIndex, newIndex);
  }

  Future<void> removeAt(int index) async {
    final handler = _requireHandler();
    await handler.removeAt(index);
  }

  Future<void> playFromIndex(int index) async {
    final handler = _requireHandler();
    await handler.playFromIndex(index);
  }

  Future<void> clear() async {
    final handler = _requireHandler();
    await handler.clearQueue();
  }

  List<String> _normalizeSongIds(Iterable<String> ids) {
    return ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
  }

  NavisPlaybackHandler _requireHandler() {
    final handler = ref.read(audioHandlerProvider);
    if (handler != null) {
      return handler;
    }
    final bootstrap = ref.read(audioBootstrapControllerProvider);
    final reason = switch (bootstrap.status) {
      AudioBootstrapStatus.initializing =>
        PlaybackUnavailableReason.initializing,
      AudioBootstrapStatus.failed => PlaybackUnavailableReason.startupFailed,
      AudioBootstrapStatus.ready => PlaybackUnavailableReason.unavailable,
    };
    throw PlaybackUnavailableException(
      reason: reason,
      message: bootstrap.errorMessage,
    );
  }
}

final queueProvider = NotifierProvider<QueueController, List<String>>(
  QueueController.new,
);

final playNextProvider = Provider<Future<void> Function(String)>((ref) {
  return (songId) => ref.read(queueProvider.notifier).playNext(songId);
});

final reorderQueueProvider = Provider<Future<void> Function(int, int)>((ref) {
  return (oldIndex, newIndex) =>
      ref.read(queueProvider.notifier).reorder(oldIndex, newIndex);
});
