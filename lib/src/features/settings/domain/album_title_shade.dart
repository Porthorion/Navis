/// Effective album-caption fade, combining Shade and Use Cover Color.
enum AlbumTitleShade {
  /// Original page-coloured fade with scheme text colours.
  classic,

  /// Dark gradient behind white text, without cover sampling.
  dark,

  /// Cover-tinted gradient with contrast-adjusted text.
  color,
}
