/// How much colour the app carries, and how soft it is.
///
/// A colour style is a second axis next to the theme mode: every style works
/// with Light, Dark, OLED and Auto. [neutral] is the original Navis look.
enum NavisColorStyle {
  /// Neutral surfaces with the accent kept faithful to the seed.
  neutral('neutral'),

  /// Soft pastel accents on gently tinted backgrounds.
  pastel('pastel'),

  /// The accent colour fills the backgrounds in deep, rich tones.
  immersive('immersive'),

  /// Warm, low-blue colours for evening listening.
  night('night');

  const NavisColorStyle(this.storageKey);

  /// Value persisted in `app_settings.color_style`.
  final String storageKey;

  /// Resolve a persisted value; unknown or missing values fall back to
  /// [neutral].
  static NavisColorStyle parse(String? value) {
    for (final style in values) {
      if (style.storageKey == value) {
        return style;
      }
    }
    return neutral;
  }
}
