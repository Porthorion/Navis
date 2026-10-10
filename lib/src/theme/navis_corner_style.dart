/// How rounded the app's chrome (cards, panels, sheets, dialogs, menus,
/// buttons, chips, inputs and navigation indicators) is.
///
/// Artwork corners are separate: they follow the Artwork Shape settings (see
/// `artworkBorderRadius`). Circular things such as avatars, round play
/// buttons, switches and progress rings stay circular in every style.
enum NavisCornerStyle {
  /// Shown as "Pill" and the default: pill-shaped buttons, chips and
  /// indicators with gently rounded cards. The stored key stays `rounded`.
  rounded,

  /// Friendlier: roughly 1.5x radii with 14 px rounded-rectangle controls.
  soft,

  /// Crisp: small radii, and 4 px corners instead of pills.
  square;

  static NavisCornerStyle parse(String? value) {
    return NavisCornerStyle.values.firstWhere(
      (style) => style.name == value,
      orElse: () => NavisCornerStyle.rounded,
    );
  }
}
