import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/providers/app_providers.dart';

enum SongPlaybackIndicatorState { inactive, current, loading }

SongPlaybackIndicatorState resolveSongPlaybackIndicatorState({
  required String songId,
  required String? currentSongId,
  required bool isLoading,
  required String? loadingSongId,
}) {
  final normalizedSongId = songId.trim();
  if (normalizedSongId.isEmpty) {
    return SongPlaybackIndicatorState.inactive;
  }
  final effectiveSongId = isLoading && loadingSongId != null
      ? loadingSongId
      : currentSongId;
  if (effectiveSongId != normalizedSongId) {
    return SongPlaybackIndicatorState.inactive;
  }
  return isLoading && loadingSongId == normalizedSongId
      ? SongPlaybackIndicatorState.loading
      : SongPlaybackIndicatorState.current;
}

SongPlaybackIndicatorState resolveQueueSongPlaybackIndicatorState({
  required int rowIndex,
  required String rowSongId,
  required List<String> queueSongIds,
  required int? currentIndex,
  required String? currentSongId,
  required bool isLoading,
  required String? loadingSongId,
}) {
  final hasCurrentIndex =
      currentIndex != null &&
      currentIndex >= 0 &&
      currentIndex < queueSongIds.length;
  if (isLoading && loadingSongId != null && loadingSongId.trim().isNotEmpty) {
    final indexedSongMatches =
        hasCurrentIndex && queueSongIds[currentIndex] == loadingSongId;
    final loadingIndex = indexedSongMatches
        ? currentIndex
        : queueSongIds.indexOf(loadingSongId);
    return loadingIndex == rowIndex
        ? SongPlaybackIndicatorState.loading
        : SongPlaybackIndicatorState.inactive;
  }
  if (hasCurrentIndex) {
    return rowIndex == currentIndex
        ? SongPlaybackIndicatorState.current
        : SongPlaybackIndicatorState.inactive;
  }
  return rowSongId == currentSongId
      ? SongPlaybackIndicatorState.current
      : SongPlaybackIndicatorState.inactive;
}

final songPlaybackIndicatorStateProvider = Provider.autoDispose
    .family<SongPlaybackIndicatorState, String>((ref, songId) {
      final playback = ref.watch(
        playerStateProvider.select(
          (snapshot) => (
            currentSongId: snapshot.currentSongId,
            isLoading: snapshot.isLoading,
            loadingSongId: snapshot.loadingSongId,
          ),
        ),
      );
      return resolveSongPlaybackIndicatorState(
        songId: songId,
        currentSongId: playback.currentSongId,
        isLoading: playback.isLoading,
        loadingSongId: playback.loadingSongId,
      );
    });

extension SongPlaybackIndicatorStateX on SongPlaybackIndicatorState {
  bool get isSelected => this != SongPlaybackIndicatorState.inactive;

  String get markerRole => switch (this) {
    SongPlaybackIndicatorState.inactive => 'none',
    SongPlaybackIndicatorState.current => 'equalizer',
    SongPlaybackIndicatorState.loading => 'progress',
  };
}

class SongPlaybackMarker extends StatelessWidget {
  const new({required this.state, super.key, this.size = 18});

  final SongPlaybackIndicatorState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return switch (state) {
      SongPlaybackIndicatorState.inactive => const SizedBox.shrink(),
      SongPlaybackIndicatorState.current => Icon(
        Icons.graphic_eq_rounded,
        size: size,
        color: color,
      ),
      SongPlaybackIndicatorState.loading => SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      ),
    };
  }
}

class ArtworkPlaybackMarker extends StatelessWidget {
  const new({
    required this.state,
    required this.child,
    super.key,
    this.markerSize = 16,
  });

  final SongPlaybackIndicatorState state;
  final Widget child;
  final double markerSize;

  @override
  Widget build(BuildContext context) {
    if (!state.isSelected) return child;
    final colors = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        child,
        PositionedDirectional(
          end: -2,
          bottom: -2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: colors.surface, width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: SongPlaybackMarker(state: state, size: markerSize),
            ),
          ),
        ),
      ],
    );
  }
}

class SongPlaybackSemantics extends StatelessWidget {
  const new({required this.state, required this.child, super.key});

  final SongPlaybackIndicatorState state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!state.isSelected) return child;
    final l10n = AppLocalizations.of(context)!;
    return Semantics(selected: true, value: l10n.nowPlayingTitle, child: child);
  }
}
