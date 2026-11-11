/// Fill used by Now Playing sheets and menus.
enum SheetStyle {
  matchNowPlaying('match_now_playing'),
  albumColor('album_color'),
  theme('theme');

  new(this.storageKey);

  /// Value persisted in `app_settings.sheet_style`.
  final String storageKey;

  /// Resolves a stored value, falling back to [matchNowPlaying] for unknown values.
  static SheetStyle parse(String? value) {
    for (final option in values) {
      if (option.storageKey == value) return option;
    }
    return matchNowPlaying;
  }
}
