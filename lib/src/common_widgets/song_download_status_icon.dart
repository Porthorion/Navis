import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/confirm_dialog.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';

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
  const new({required this.status, this.progress = 0.0});

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
final songDownloadStateProvider = Provider.autoDispose
    .family<SongDownloadState, String>((ref, songId) {
      // Select only this song's entries so a row rebuilds only when its own cache
      // or download state changes, not on every queue progress write.
      // 1. Check cache type (rolling / permanent).
      final cacheType = ref.watch(
        cachedSongTypesProvider.select((types) => types.asData?.value[songId]),
      );

      if (cacheType == CacheType.permanent) {
        return const SongDownloadState(status: SongDownloadStatus.downloaded);
      }

      // 2. Check download queue.
      final queued = ref.watch(
        downloadQueueProvider.select((queue) {
          for (final item
              in queue.asData?.value ?? const <DownloadQueueTableData>[]) {
            if (item.songId == songId) {
              return (status: item.status, progress: item.progress);
            }
          }
          return null;
        }),
      );
      if (queued != null) {
        if (queued.status == DownloadStatus.downloading) {
          return SongDownloadState(
            status: SongDownloadStatus.downloading,
            progress: queued.progress.clamp(0.0, 1.0),
          );
        }
        if (queued.status == DownloadStatus.queued) {
          return const SongDownloadState(status: SongDownloadStatus.queued);
        }
        // Failed items — treat as "none" so the user can re-download.
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
  const new({
    required this.songId,
    this.onDownload,
    this.size = 24.0,
    super.key,
  });

  final String songId;

  /// Called when the user taps the download icon (status == none).
  final VoidCallback? onDownload;

  final double size;

  void _startDownload() {
    NavisHaptics.confirm(HapticCategory.likesAndAlerts);
    onDownload!();
  }

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
        onPressed: onDownload == null ? null : _startDownload,
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
          color: NavisTokens.of(context).success,
        ),
        tooltip: l10n.deleteDownloadAction,
        onPressed: () => confirmAndDeleteDownload(context, ref, songId),
        constraints: const BoxConstraints(),
        padding: const EdgeInsets.all(8),
      ),
      SongDownloadStatus.cached =>
        onDownload == null
            ? _maybeTooltip(
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
              )
            : IconButton(
                icon: Icon(
                  Icons.schedule,
                  size: size * 0.85,
                  color: theme.colorScheme.tertiary,
                ),
                tooltip: l10n.songStatusCachedTooltip,
                onPressed: onDownload == null ? null : _startDownload,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(8),
              ),
    };
  }
}

/// The non-interactive download state of a phone song row, drawn inline
/// before the artist on the row's second line: a filled circle with a down
/// arrow once downloaded, a progress ring with a small arrow while
/// downloading, a faint dashed ring while queued, nothing otherwise
/// (rolling-cached songs included). Downloading and removing live in the
/// row's menu.
///
/// A visible mark carries its own 4 dp gap towards the text, so rows without
/// a state take no extra width.
class SongDownloadStatusGlyph extends ConsumerWidget {
  const new({required this.songId, super.key});

  final String songId;

  /// The 14 dp box of the downloading ring.
  @visibleForTesting
  static const boxKey = ValueKey('song-download-status-ring');

  /// The 14 dp box of the queued dashed ring.
  @visibleForTesting
  static const queuedKey = ValueKey('song-download-status-queued');

  static const _size = 14.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(songDownloadStateProvider(songId));
    final l10n = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;
    final (label, value, glyph) = switch (state.status) {
      SongDownloadStatus.downloaded => (
        l10n.songStatusDownloaded,
        null,
        Icon(
          Icons.download_for_offline,
          size: _size,
          color: NavisTokens.of(context).success,
        ),
      ),
      SongDownloadStatus.downloading => (
        l10n.songStatusDownloading,
        l10n.notificationDownloadProgressPercent(
          (state.progress * 100).round(),
        ),
        SizedBox(
          key: boxKey,
          width: _size,
          height: _size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: state.progress,
                strokeWidth: 1.75,
                color: primary,
              ),
              Icon(Icons.arrow_downward, size: 8, color: primary),
            ],
          ),
        ),
      ),
      SongDownloadStatus.queued => (
        l10n.songStatusQueued,
        null,
        CustomPaint(
          key: queuedKey,
          size: const Size.square(_size),
          painter: _DashedRingPainter(primary.withValues(alpha: .5)),
        ),
      ),
      SongDownloadStatus.none ||
      SongDownloadStatus.cached => (null, null, null),
    };
    if (label == null || glyph == null) return const SizedBox.shrink();
    return Semantics(
      label: label,
      value: value,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 4),
        child: glyph,
      ),
    );
  }
}

/// A still ring of ten dashes: the queued state (no animation).
class _DashedRingPainter extends CustomPainter {
  const _DashedRingPainter(this.color);

  final Color color;

  static const _stroke = 1.75;
  static const _dashes = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    final rect = (Offset.zero & size).deflate(_stroke / 2);
    const step = 2 * math.pi / _dashes;
    for (var i = 0; i < _dashes; i++) {
      canvas.drawArc(rect, i * step, step * .55, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.color != color;
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
  final confirmed = await confirmRemoveDownload(context);

  if (!confirmed || !context.mounted) return;

  await ref.read(downloadServiceProvider).removeDownloadedTrack(songId);
}
