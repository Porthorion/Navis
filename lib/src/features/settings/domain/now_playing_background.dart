/// Background treatment for Now Playing.
enum NowPlayingBackground {
  tinted('tinted'),
  artwork('artwork'),
  plain('plain');

  new(this.storageKey);

  /// Value persisted in `app_settings.now_playing_background`.
  final String storageKey;

  /// Resolves a stored value, falling back to [tinted] for unknown values.
  static NowPlayingBackground parse(String? value) {
    for (final option in values) {
      if (option.storageKey == value) return option;
    }
    return tinted;
  }
}
