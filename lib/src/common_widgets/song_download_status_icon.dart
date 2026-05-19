import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

/// The resolved download/cache state of a single song.
enum SongDownloadStatus {
  /// Not cached, not downloaded, not queued.
  none,

  /// In the rolling cache (temporary).
  cached,

  /// Queued for download but not yet started.
  queued,

  /// Actively downloading (has progress 0.0–1.0).
  downloading,

  /// Permanently downloaded.
  downloaded,
}

/// Resolved state of a song's download / cache status, including progress.
class SongDownloadState {
  const SongDownloadState({
    required this.status,
    this.progress = 0.0,
  });

  static const none = SongDownloadState(status: SongDownloadStatus.none);

  final SongDownloadStatus status;

  /// Download progress (0.0–1.0), meaningful only when
  /// [status] == [SongDownloadStatus.downloading].
  final double progress;
}

/// Provider that merges cached-track information and the download queue into
/// a single [SongDownloadState] per song ID.
///
/// Priority: downloaded > downloading > queued > cached > none.
final songDownloadStateProvider = Provider.family<SongDownloadState, String>((
  ref,
  songId,
) {
  // 1. Check cache type (rolling / permanent).
  final cachedTypes = ref.watch(cachedSongTypesProvider).asData?.value;
  final cacheType = cachedTypes?[songId];

  if (cacheType == CacheType.permanent) {
    return const SongDownloadState(status: SongDownloadStatus.downloaded);
  }

  // 2. Check download queue.
  final queue = ref.watch(downloadQueueProvider).asData?.value;
  if (queue != null) {
    for (final item in queue) {
      if (item.songId == songId) {
        if (item.status == DownloadStatus.downloading) {
          return SongDownloadState(
            status: SongDownloadStatus.downloading,
            progress: item.progress.clamp(0.0, 1.0),
          );
        }
        if (item.status == DownloadStatus.queued) {
          return const SongDownloadState(status: SongDownloadStatus.queued);
        }
        // Failed items — treat as "none" so the user can re-download.
        break;
      }
    }
  }

  // 3. Rolling cache.
  if (cacheType == CacheType.rolling) {
    return const SongDownloadState(status: SongDownloadStatus.cached);
  }

  return SongDownloadState.none;
});

/// An icon widget that replaces both the old download button and the
/// prior cache-status indicator.
///
/// Shows:
/// * **Download icon** — song is not cached/queued/downloaded (tappable).
/// * **Indeterminate spinner** — song is queued (pending).
/// * **Circular progress** — song is actively downloading.
/// * **Green check** — song is permanently downloaded.
/// * **Purple clock** — song is in the rolling cache (with tooltip).
///
/// When [onDownload] is null the download icon is disabled.
class SongDownloadStatusIcon extends ConsumerWidget {
  const SongDownloadStatusIcon({
    required this.songId,
    this.onDownload,
    this.size = 24.0,
    super.key,
  });

  final String songId;

  /// Called when the user taps the download icon (status == none).
  final VoidCallback? onDownload;

  final double size;

  /// Wraps a child in a [Tooltip] only on desktop platforms.
  /// On mobile/touch platforms, returns the child unchanged.
  static Widget _maybeTooltip(Widget child, String message) {
    if (!isDesktopRuntime) return child;
    return Tooltip(message: message, child: child);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(songDownloadStateProvider(songId));
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return switch (state.status) {
      SongDownloadStatus.none => IconButton(
        icon: Icon(Icons.download_outlined, size: size),
        tooltip: l10n.downloadAction,
        onPressed: onDownload,
        constraints: const BoxConstraints(),
        padding: const EdgeInsets.all(8),
      ),
      SongDownloadStatus.queued => _maybeTooltip(
        SizedBox(
          width: size + 16,
          height: size + 16,
          child: Center(
            child: SizedBox(
              width: size * 0.75,
              height: size * 0.75,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
        l10n.songStatusQueued,
      ),
      SongDownloadStatus.downloading => _maybeTooltip(
        SizedBox(
          width: size + 16,
          height: size + 16,
          child: Center(
            child: SizedBox(
              width: size * 0.75,
              height: size * 0.75,
              child: CircularProgressIndicator(
                value: state.progress,
                strokeWidth: 2.5,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        l10n.songStatusDownloading,
      ),
      SongDownloadStatus.downloaded => IconButton(
        icon: Icon(
          Icons.check_circle,
          size: size,
          color: Colors.green,
        ),
        tooltip: l10n.deleteDownloadAction,
        onPressed: () => confirmAndDeleteDownload(context, ref, songId),
        constraints: const BoxConstraints(),
        padding: const EdgeInsets.all(8),
      ),
      SongDownloadStatus.cached => _maybeTooltip(
        SizedBox(
          width: size + 16,
          height: size + 16,
          child: Center(
            child: Icon(
              Icons.schedule,
              size: size * 0.85,
              color: theme.colorScheme.tertiary,
            ),
          ),
        ),
        l10n.songStatusCachedTooltip,
      ),
    };
  }
}

/// Shows a confirmation dialog and, if confirmed, deletes the permanently
/// downloaded file for [songId].
///
/// This is public so it can be reused by other menus (Now Playing settings,
/// song / album context menus) without duplicating the logic.
Future<void> confirmAndDeleteDownload(
  BuildContext context,
  WidgetRef ref,
  String songId,
) async {
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.downloadsRemoveConfirmTitle),
      content: Text(l10n.downloadsRemoveConfirmContent),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.downloadsRemoveAction),
        ),
      ],
    ),
  );

  if (confirmed != true || !context.mounted) return;

  await ref.read(downloadServiceProvider).removeDownloadedTrack(songId);
}
