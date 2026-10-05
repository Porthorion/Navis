import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/content_shelf.dart';
import 'package:navis/src/common_widgets/external_album_card.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/integrations/presentation/deezer_release_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/app_logger.dart';

/// How long a tap waits for the server to confirm a remote album.
const Duration _kRemoteAlbumCheckTimeout = Duration(seconds: 5);

/// "Oct 2 • Single": the release day and type of [release], for its card.
String homeNewReleaseDetail(
  AppLocalizations l10n,
  Locale locale,
  HomeNewRelease release,
) {
  return <String?>[
    DateFormat.MMMd(locale.toString()).format(release.releasedOn),
    deezerReleaseTypeLabel(l10n, release.album.recordType),
  ].nonNulls.join(' • ');
}

/// Opens a New releases card: the library album when the library has the
/// release; else the server's remote album `ext-deezer-album-<id>` when
/// `getAlbum` confirms the server has it; else the release sheet.
Future<void> openHomeNewRelease(
  BuildContext context,
  WidgetRef ref,
  HomeNewRelease release,
) async {
  final libraryAlbumId = release.libraryAlbumId;
  if (libraryAlbumId != null) {
    NavService.openAlbumDetail(context, ref, libraryAlbumId);
    return;
  }
  final remoteAlbumId = 'ext-deezer-album-${release.album.id}';
  final api = ref.read(subsonicApiProvider);
  if (api != null) {
    try {
      await api.getAlbum(remoteAlbumId).timeout(_kRemoteAlbumCheckTimeout);
      if (!context.mounted) return;
      NavService.openAlbumDetail(context, ref, remoteAlbumId);
      return;
    } on Object catch (error) {
      AppLogger.debug('New releases: no remote album on the server: $error');
    }
  }
  if (!context.mounted) return;
  await showDeezerReleaseSheet(
    context,
    ref,
    album: release.album,
    artistName: release.artistName,
    feature: IntegrationFeature.deezerNewReleases,
    releasedOn: release.releasedOn,
  );
}

/// The New releases shelf: Home's album carousel with a card per release
/// showing its title, artist and "Oct 2 • Single".
class HomeNewReleasesShelf extends ConsumerStatefulWidget {
  const new({
    required this.releases,
    required this.horizontalPadding,
    this.compact = false,
    super.key,
  });

  final List<HomeNewRelease> releases;
  final double horizontalPadding;

  /// Home's compact density.
  final bool compact;

  @override
  ConsumerState<HomeNewReleasesShelf> createState() =>
      _HomeNewReleasesShelfState();
}

class _HomeNewReleasesShelfState extends ConsumerState<HomeNewReleasesShelf> {
  /// The release a tap is opening; further taps wait for it.
  int? _opening;

  Future<void> _open(HomeNewRelease release) async {
    if (_opening != null) return;
    setState(() => _opening = release.album.id);
    try {
      await openHomeNewRelease(context, ref, release);
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final extent = ContentLayout.shelfCardExtent(
          width,
          compact: widget.compact,
        );
        final usableWidth = (width - widget.horizontalPadding * 2).clamp(
          0.0,
          double.infinity,
        );
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
          child: ContentShelf(
            height: extent,
            extent: extent,
            gap: ContentLayout.gap(usableWidth),
            itemCount: widget.releases.length,
            itemBuilder: (context, index) {
              final release = widget.releases[index];
              return ExternalAlbumCard(
                key: ValueKey<String>('home-new-release-${release.album.id}'),
                title: release.album.title,
                subtitle: release.artistName,
                detail: homeNewReleaseDetail(l10n, locale, release),
                coverUrl: deezerReleaseCoverUrl(release.album),
                feature: IntegrationFeature.deezerNewReleases,
                extent: extent,
                onTap: () => unawaited(_open(release)),
              );
            },
          ),
        );
      },
    );
  }
}
