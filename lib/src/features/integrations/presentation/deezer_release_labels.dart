import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/deezer_models.dart';

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

/// The best cover URL of [album] for a card.
String? deezerReleaseCoverUrl(DeezerAlbum album) =>
    album.coverBig ?? album.coverXl ?? album.coverMedium;
