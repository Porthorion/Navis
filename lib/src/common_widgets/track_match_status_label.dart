import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';

/// Why a virtual-playlist row (a ListenBrainz weekly playlist, Trending Now,
/// "This Is" an artist) has no song to play yet.
enum TrackMatchLabelKind {
  /// The server is still being searched.
  matching,

  /// Neither the library nor the server has the song.
  unavailable,

  /// Several songs could be the one; none was picked.
  ambiguous,
}

/// The short status that rides on such a row's title line ("Not on server",
/// "Unclear match", "Matching"), with the full sentence as its tooltip and
/// accessible label. Rows that show it also fade to
/// [TrackMatchStatusLabel.unavailableOpacity] when the song is unavailable
/// and offer a Search action.
class TrackMatchStatusLabel extends StatelessWidget {
  const new({required this.kind, super.key});

  /// The opacity of an unavailable or ambiguous row.
  static const double unavailableOpacity = 0.58;

  final TrackMatchLabelKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final (String shortLabel, String label, IconData? icon) = switch (kind) {
      TrackMatchLabelKind.matching => (
        l10n.weeklyPlaylistMatching,
        l10n.weeklyPlaylistMatching,
        null,
      ),
      TrackMatchLabelKind.unavailable => (
        l10n.weeklyPlaylistTrackUnavailableShort,
        l10n.weeklyPlaylistTrackUnavailable,
        Icons.cloud_off_rounded,
      ),
      TrackMatchLabelKind.ambiguous => (
        l10n.weeklyPlaylistAmbiguousMatchShort,
        l10n.weeklyPlaylistAmbiguousMatch,
        Icons.help_outline_rounded,
      ),
    };
    return Tooltip(
      // "Matching" is already short and matches the hourglass button's
      // tooltip, so it needs no second tooltip.
      message: shortLabel == label ? '' : label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Row(
          key: const ValueKey<String>('weekly-track-status'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                shortLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
