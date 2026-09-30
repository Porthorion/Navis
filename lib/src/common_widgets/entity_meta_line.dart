import 'package:navis/l10n/app_localizations.dart';

/// Summary for an album or other song collection, such as
/// "2026 • 16 songs • 52 min".
///
/// Unknown parts are omitted rather than shown as placeholders. Pass the
/// collection's full song count and duration, not a filtered subset, so the
/// summary describes the release itself.
String entityCollectionSummary(
  AppLocalizations l10n, {
  required int songCount,
  int? year,
  int? totalSeconds,
}) {
  final seconds = totalSeconds ?? 0;
  return <String>[
    if (year != null && year > 0) '$year',
    l10n.playlistsSongCount(songCount),
    if (seconds >= 60) formatCollectionDuration(l10n, seconds),
  ].join(' • ');
}

/// Total running time rounded to whole minutes, e.g. "52 min" or
/// "1 hr 5 min".
String formatCollectionDuration(AppLocalizations l10n, int totalSeconds) {
  final totalMinutes = (totalSeconds / 60).round();
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  return hours == 0
      ? l10n.entityTotalDurationMinutes(minutes)
      : l10n.entityTotalDurationHours(hours, minutes);
}
