import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/external_artwork_image.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// A Deezer release that a sheet shows, and the feature whose switch covers
/// it (`deezer.missingAlbums` on artist pages, `deezer.newReleases` on Home).
typedef DeezerReleaseKey = ({int albumId, IntegrationFeature feature});

/// `/album/{id}` for the release sheet, through the disk cache; null while
/// the key's feature is off.
final deezerReleaseDetailsProvider = FutureProvider.autoDispose
    .family<DeezerAlbum?, DeezerReleaseKey>((ref, key) async {
      final allowed = ref.watch(
        integrationPolicyProvider.select(
          (policy) => policy.allows(key.feature),
        ),
      );
      if (!allowed) return null;
      final cancelToken = CancelToken();
      ref.onDispose(cancelToken.cancel);
      return await ref
          .watch(deezerCatalogProvider)
          .album(key.albumId, cancelToken: cancelToken);
    });

/// The release year of [album], or null when Deezer gave no date.
String? deezerReleaseYear(DeezerAlbum album) {
  final date = album.releaseDate ?? '';
  final year = date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;
  return year == null || year <= 0 ? null : '$year';
}

/// "Album", "EP", "Single" or "Compilation" for Deezer's `record_type`.
String? deezerReleaseTypeLabel(AppLocalizations l10n, String? recordType) {
  return switch (recordType?.toLowerCase()) {
    'album' => l10n.deezerReleaseTypeAlbum,
    'ep' => l10n.deezerReleaseTypeEp,
    'single' => l10n.deezerReleaseTypeSingle,
    'compile' => l10n.deezerReleaseTypeCompilation,
    _ => null,
  };
}

/// "2021 • EP": the year and type of [album], for cards.
String deezerReleaseSummary(AppLocalizations l10n, DeezerAlbum album) {
  return <String?>[
    deezerReleaseYear(album),
    deezerReleaseTypeLabel(l10n, album.recordType),
  ].nonNulls.join(' • ');
}

/// The best cover URL of [album] for a card or the sheet.
String? deezerReleaseCoverUrl(DeezerAlbum album) =>
    album.coverBig ?? album.coverXl ?? album.coverMedium;

/// Shows a Deezer release that is not on the server: cover, title, artist,
/// year, type and track count, and "Search your server", which searches the
/// server for it (the server may hold it under another name, or fetch it
/// from a remote catalogue).
///
/// A dialog on desktop, a bottom sheet elsewhere. [feature] is the switch the
/// release belongs to; it gates the cover and the track-count request.
Future<void> showDeezerReleaseSheet(
  BuildContext context,
  WidgetRef ref, {
  required DeezerAlbum album,
  required String artistName,
  required IntegrationFeature feature,
}) {
  void searchServer(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
    NavService.openSearch(
      context,
      ref,
      '${album.title} $artistName'.trim(),
      filter: SearchResultType.albums,
    );
  }

  Widget body(BuildContext sheetContext, {required bool dialog}) =>
      DeezerReleaseSheetBody(
        album: album,
        artistName: artistName,
        feature: feature,
        padding: dialog
            ? const EdgeInsets.all(NavisSpace.xl)
            : const EdgeInsets.fromLTRB(
                NavisSpace.xl,
                0,
                NavisSpace.xl,
                NavisSpace.xl,
              ),
        onSearchServer: () => searchServer(sheetContext),
      );

  if (resolveAdaptiveContextFor(context).desktopRuntime) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => Dialog(
        child: SizedBox(width: 440, child: body(dialogContext, dialog: true)),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) =>
        SafeArea(child: body(sheetContext, dialog: false)),
  );
}

/// The content of [showDeezerReleaseSheet].
class DeezerReleaseSheetBody extends ConsumerWidget {
  const new({
    required this.album,
    required this.artistName,
    required this.feature,
    required this.onSearchServer,
    this.padding = const EdgeInsets.all(NavisSpace.xl),
    super.key,
  });

  static const coverExtent = 112.0;

  final DeezerAlbum album;
  final String artistName;
  final IntegrationFeature feature;
  final VoidCallback onSearchServer;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final secondary = theme.colorScheme.onSurfaceVariant;
    final details = ref
        .watch(
          deezerReleaseDetailsProvider((albumId: album.id, feature: feature)),
        )
        .value;
    // The card's year and type; the release details add the track count.
    final trackCount = details?.trackCount ?? album.trackCount;
    final meta = <String?>[
      deezerReleaseYear(album) ??
          (details == null ? null : deezerReleaseYear(details)),
      deezerReleaseTypeLabel(l10n, album.recordType ?? details?.recordType),
      if (trackCount != null && trackCount > 0)
        l10n.deezerReleaseTrackCount(trackCount),
    ].nonNulls.join(' • ');
    final radius = artworkBorderRadius(
      ref.watch(coverArtShapeProvider),
      extent: coverExtent,
    );
    Widget placeholder(BuildContext _) => const CoverArtImage(
      coverArtId: null,
      width: coverExtent,
      height: coverExtent,
      placeholderIcon: Icons.album_outlined,
    );
    final coverUrl = deezerReleaseCoverUrl(album);

    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              ClipRRect(
                borderRadius: radius,
                child: SizedBox.square(
                  dimension: coverExtent,
                  child: coverUrl == null
                      ? placeholder(context)
                      : ExternalArtworkImage(
                          url: coverUrl,
                          feature: feature,
                          fit: BoxFit.cover,
                          fallbackBuilder: placeholder,
                        ),
                ),
              ),
              const SizedBox(width: NavisSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      album.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleLarge,
                    ),
                    const SizedBox(height: NavisSpace.xxs),
                    Text(
                      artistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(color: secondary),
                    ),
                    if (meta.isNotEmpty) ...<Widget>[
                      const SizedBox(height: NavisSpace.xxs),
                      Text(
                        meta,
                        key: const ValueKey<String>('deezer-release-meta'),
                        style: textTheme.bodyMedium?.copyWith(color: secondary),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: NavisSpace.xl),
          FilledButton.tonalIcon(
            key: const ValueKey<String>('deezer-release-search-server'),
            onPressed: onSearchServer,
            icon: const Icon(Icons.search_rounded),
            label: Text(l10n.deezerReleaseSearchServer),
          ),
        ],
      ),
    );
  }
}
