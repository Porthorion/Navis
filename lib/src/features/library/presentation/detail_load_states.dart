import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Where an artist or album page stands while the library does not hold
/// enough of its entity to show (a remote `ext-…` entity, or one not synced
/// yet): the page's hydration is [running], has [settled] (the entity is
/// stored), or has [failed].
enum DetailHydrationPhase { running, settled, failed }

/// Whether a page's hydration [result] confirms what the server holds: only
/// a hydration that succeeded. No request (null), a partial or skipped one
/// confirms nothing, so a remote artist without albums is never shown as
/// having none on their account.
bool detailHydrationConfirmed(LibrarySyncState? result) =>
    result?.status == LibrarySyncStatus.succeeded;

/// Whether a page's hydration [result] reports that the server did not
/// answer: the request failed, was cancelled or was deferred by the network
/// policy. A refresh of a page that already shows its entity reports these.
bool detailHydrationFailed(LibrarySyncState? result) =>
    switch (result?.status) {
      LibrarySyncStatus.failed ||
      LibrarySyncStatus.cancelled ||
      LibrarySyncStatus.deferred => true,
      _ => false,
    };

/// How long an artist or album page waits for the server before it offers
/// Retry and a search. The request keeps running: a late answer still fills
/// the page.
const Duration kDetailHydrationTimeout = Duration(seconds: 20);

/// Marks the content of an artist or album page once it shows its entity
/// (not the loading or failed view), for diagnostics.
const detailPageShownKey = ValueKey<String>('detail-page-shown');

/// The size of the artwork in [DetailLoadingView] and [DetailLoadFailedView].
const double kDetailStateArtworkExtent = 96;

/// The page an artist or album shows until it has its name and albums
/// (artist) or title and tracks (album): the artwork the library already has
/// (or a placeholder), the name when known, and [status] ("Loading Remote
/// Album…") beside a small spinner, above a quiet outline of the content to
/// come. The page's own app bar carries the back button.
class DetailLoadingView extends StatelessWidget {
  const new({
    required this.status,
    required this.artwork,
    required this.content,
    this.name,
    this.isRemote = false,
    super.key,
  });

  final String status;

  /// A [kDetailStateArtworkExtent] square.
  final Widget artwork;
  final String? name;
  final bool isRemote;

  /// The outline of what the page will show: [DetailAlbumGridOutline] or
  /// [DetailTrackListOutline].
  final Widget content;

  static const loadingKey = ValueKey<String>('detail-page-loading');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      key: loadingKey,
      label: status,
      liveRegion: true,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          NavisSpace.md,
          NavisSpace.lg,
          NavisSpace.md,
          NavisSpace.xl,
        ),
        children: <Widget>[
          _DetailStateHeader(
            artwork: artwork,
            name: name,
            isRemote: isRemote,
            details: <Widget>[
              Row(
                children: <Widget>[
                  SizedBox.square(
                    dimension: NavisSpace.md,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: secondary,
                    ),
                  ),
                  const SizedBox(width: NavisSpace.xs),
                  Flexible(
                    child: Text(
                      status,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: secondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: NavisSpace.xxl),
          ExcludeSemantics(child: content),
        ],
      ),
    );
  }
}

/// The page an artist or album shows when the server could not provide it:
/// [title], a short reason, Retry, and "Search for `name`" when the name is
/// known, so a tap never ends on an empty page.
class DetailLoadFailedView extends StatelessWidget {
  const new({
    required this.title,
    required this.artwork,
    required this.onRetry,
    this.name,
    this.isRemote = false,
    this.onSearch,
    super.key,
  });

  final String title;

  /// A [kDetailStateArtworkExtent] square.
  final Widget artwork;
  final String? name;
  final bool isRemote;
  final VoidCallback onRetry;

  /// Searches for [name]; no search action without one.
  final VoidCallback? onSearch;

  static const failedKey = ValueKey<String>('detail-page-failed');
  static const retryKey = ValueKey<String>('detail-page-retry');
  static const searchKey = ValueKey<String>('detail-page-search');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final searchName = name;
    return ListView(
      key: failedKey,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        NavisSpace.md,
        NavisSpace.lg,
        NavisSpace.md,
        NavisSpace.xl,
      ),
      children: <Widget>[
        _DetailStateHeader(
          artwork: artwork,
          name: name,
          isRemote: isRemote,
          details: const <Widget>[],
        ),
        ErrorState(
          title: title,
          message: l10n.detailLoadFailedMessage,
          onRetry: onRetry,
          retryKey: retryKey,
          secondaryAction: onSearch != null && searchName != null
              ? OutlinedButton.icon(
                  key: searchKey,
                  onPressed: onSearch,
                  icon: const Icon(Icons.search_rounded),
                  label: Text(l10n.detailSearchFor(searchName)),
                )
              : null,
        ),
      ],
    );
  }
}

/// Artwork on the left, then the name (when known), [details] and the
/// Remote mark for a remote entity.
class _DetailStateHeader extends StatelessWidget {
  const new({
    required this.artwork,
    required this.name,
    required this.isRemote,
    required this.details,
  });

  final Widget artwork;
  final String? name;
  final bool isRemote;
  final List<Widget> details;

  @override
  Widget build(BuildContext context) {
    final knownName = name?.trim();
    return Row(
      children: <Widget>[
        SizedBox.square(dimension: kDetailStateArtworkExtent, child: artwork),
        const SizedBox(width: NavisSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (knownName != null && knownName.isNotEmpty) ...<Widget>[
                Text(
                  knownName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: NavisSpace.xxs),
              ],
              ...details,
              if (isRemote) ...<Widget>[
                const SizedBox(height: NavisSpace.xs),
                const RemoteSourceIndicator(
                  variant: RemoteSourceIndicatorVariant.chip,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A still block standing in for content that is loading (also used by the
/// artist page's loading skeleton).
class DetailOutlineBlock extends StatelessWidget {
  const new({required this.height, this.width, this.borderRadius, super.key});

  final double height;
  final double? width;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: borderRadius ?? NavisRadius.xsAll,
      ),
    );
  }
}

/// The outline of an artist page's album grid: a section title and one row
/// of album squares, sized like the grid below it will be.
class DetailAlbumGridOutline extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = ref.watch(gridArtworkSizeProvider);
    final radius = artworkBorderRadius(
      ref.watch(coverArtShapeProvider),
      extent: double.infinity,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final grid = ContentLayout.albums(constraints.maxWidth, size);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const DetailOutlineBlock(height: 20, width: 96),
            const SizedBox(height: NavisSpace.md),
            Row(
              children: <Widget>[
                for (var column = 0; column < grid.columns; column++) ...[
                  if (column > 0) SizedBox(width: grid.gap),
                  DetailOutlineBlock(
                    height: grid.extent,
                    width: grid.extent,
                    borderRadius: radius,
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The outline of an album page's track list: a few numbered rows.
class DetailTrackListOutline extends StatelessWidget {
  const new({super.key});

  static const _rows = 6;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        for (var row = 0; row < _rows; row++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NavisSpace.xs),
            child: Row(
              children: <Widget>[
                const DetailOutlineBlock(height: 12, width: 16),
                const SizedBox(width: NavisSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      FractionallySizedBox(
                        widthFactor: row.isEven ? 0.7 : 0.55,
                        child: const DetailOutlineBlock(height: 14),
                      ),
                      const SizedBox(height: NavisSpace.xxs),
                      const FractionallySizedBox(
                        widthFactor: 0.35,
                        child: DetailOutlineBlock(height: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: NavisSpace.md),
                const DetailOutlineBlock(height: 12, width: 32),
              ],
            ),
          ),
      ],
    );
  }
}

/// The app bar's Refresh action of an artist or album page: fetches the
/// entity from the server again, showing a spinner while it runs.
class DetailRefreshButton extends StatelessWidget {
  const new({required this.refreshing, required this.onRefresh, super.key});

  final bool refreshing;
  final VoidCallback onRefresh;

  static const buttonKey = ValueKey<String>('detail-page-refresh');

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: buttonKey,
      tooltip: AppLocalizations.of(context)!.detailRefreshAction,
      onPressed: refreshing ? null : onRefresh,
      icon: AnimatedSwitcher(
        duration: MotionPolicy.of(context).surface,
        child: refreshing
            ? const SizedBox.square(
                key: ValueKey<String>('detail-refresh-running'),
                dimension: NavisSpace.lg,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(
                Icons.refresh,
                key: ValueKey<String>('detail-refresh-idle'),
              ),
      ),
    );
  }
}
