import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/genre_key.dart';

/// The genres of an album or song as tappable chips that wrap onto further
/// rows. A chip opens the genre's page; while the Genres page is hidden it
/// offers a link to the Library pages setting instead.
class GenreChips extends ConsumerWidget {
  const new({required this.genres, super.key});

  /// Genre names, already deduplicated by merge key.
  final List<String> genres;

  void _open(BuildContext context, WidgetRef ref, String name) {
    if (ref.read(showGenresPageProvider)) {
      NavService.openGenreDetail(context, ref, genreKey(name));
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    showAppNotice(
      context,
      message: l10n.genreDisabledNotice,
      duration: const Duration(seconds: 5),
      actionLabel: l10n.genreDisabledShowAction,
      onAction: () {
        if (context.mounted) {
          NavService.openAppearanceLibraryPages(context, ref);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (genres.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: <Widget>[
        for (final name in genres)
          ActionChip(
            key: ValueKey<String>('genre-chip-${genreKey(name)}'),
            label: Text(name),
            visualDensity: VisualDensity.compact,
            onPressed: () => _open(context, ref, name),
          ),
      ],
    );
  }
}

/// The distinct genres of [songGenres] (one list per song) by merge key, each
/// under its most common spelling, the most common genre first. This is how an
/// album, which stores no genres of its own, gets its chips.
List<String> albumGenres(Iterable<List<String>?> songGenres) {
  final spellingCounts = <String, Map<String, int>>{};
  for (final genres in songGenres) {
    for (final name in genres ?? const <String>[]) {
      final key = genreKey(name);
      if (key.isEmpty) continue;
      final counts = spellingCounts.putIfAbsent(key, () => <String, int>{});
      counts[name] = (counts[name] ?? 0) + 1;
    }
  }
  final genres = <(String name, int total)>[
    for (final counts in spellingCounts.values)
      (
        (counts.entries.toList()..sort(
              (a, b) => b.value != a.value
                  ? b.value.compareTo(a.value)
                  : a.key.compareTo(b.key),
            ))
            .first
            .key,
        counts.values.fold(0, (a, b) => a + b),
      ),
  ]..sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1));
  return <String>[for (final genre in genres) genre.$1];
}
