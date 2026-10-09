import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Which Appearance shape setting a piece of artwork follows.
enum ArtworkShapeRole {
  /// Album, song and playlist covers (Artwork Shape: square or rounded).
  cover,

  /// The Now Playing cover (Now Playing Art Shape).
  nowPlaying,

  /// Artist images (Artist Card Shape).
  artist,
}

/// The corners of artwork drawn [extent] logical pixels wide in the user's
/// [shape] (`square`, `rounded` or `circle`).
///
/// Rounded corners scale with the artwork so a 40 px row thumbnail is not
/// clipped like a 300 px cover: [NavisRadius.xs] below 40 px,
/// [NavisRadius.sm] below 96 px and [NavisRadius.md] otherwise. Pass
/// `double.infinity` for artwork that fills a card or header. A circle is
/// fully rounded; callers that know the artwork is square may clip it with
/// an oval instead.
BorderRadius artworkBorderRadius(String shape, {required double extent}) {
  switch (shape) {
    case 'square':
      return BorderRadius.zero;
    case 'circle':
      return NavisRadius.pillAll;
    default:
      if (extent < 40) return NavisRadius.xsAll;
      if (extent < 96) return NavisRadius.smAll;
      return NavisRadius.mdAll;
  }
}
