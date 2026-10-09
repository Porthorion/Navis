import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Resolved chrome radii for a [NavisCornerStyle].
///
/// `NavisRadius` stays the const `rounded` scale; call sites that should
/// follow the user's corner style read this extension instead, through
/// `NavisShapeData.of(context)`. Component themes in `navis_theme.dart` are
/// built from the same table.
@immutable
class NavisShapeData extends ThemeExtension<NavisShapeData> {
  const new({
    required this.style,
    required this.xs,
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
    required this.control,
  });

  /// The radius table for [style].
  factory forStyle(NavisCornerStyle style) {
    return switch (style) {
      NavisCornerStyle.rounded => rounded,
      NavisCornerStyle.soft => soft,
      NavisCornerStyle.square => square,
    };
  }

  /// Exactly today's [NavisRadius] scale; buttons and indicators are pills.
  static const NavisShapeData rounded = NavisShapeData(
    style: NavisCornerStyle.rounded,
    xs: NavisRadius.xs,
    sm: NavisRadius.sm,
    md: NavisRadius.md,
    lg: NavisRadius.lg,
    xl: NavisRadius.xl,
    control: NavisRadius.pill,
  );

  static const NavisShapeData soft = NavisShapeData(
    style: NavisCornerStyle.soft,
    xs: 6,
    sm: 12,
    md: 18,
    lg: 24,
    xl: 28,
    control: NavisRadius.pill,
  );

  static const NavisShapeData square = NavisShapeData(
    style: NavisCornerStyle.square,
    xs: 2,
    sm: 2,
    md: 4,
    lg: 4,
    xl: 6,
    control: 4,
  );

  final NavisCornerStyle style;
  final double xs;
  final double sm;
  final double md;
  final double lg;
  final double xl;

  /// Corner of buttons, chips, segmented buttons and navigation indicators:
  /// a pill in `rounded` and `soft`, 4 px in `square`.
  final double control;

  BorderRadius get xsAll => BorderRadius.circular(xs);
  BorderRadius get smAll => BorderRadius.circular(sm);
  BorderRadius get mdAll => BorderRadius.circular(md);
  BorderRadius get lgAll => BorderRadius.circular(lg);
  BorderRadius get xlAll => BorderRadius.circular(xl);
  BorderRadius get controlAll => BorderRadius.circular(control);

  /// Top-only corners for bottom sheets.
  BorderRadius get sheetTop => BorderRadius.vertical(top: Radius.circular(xl));

  /// A rectangular shape with [radius].
  static RoundedRectangleBorder shapeOf(BorderRadius radius) =>
      RoundedRectangleBorder(borderRadius: radius);

  RoundedRectangleBorder get smShape => shapeOf(smAll);
  RoundedRectangleBorder get mdShape => shapeOf(mdAll);
  RoundedRectangleBorder get lgShape => shapeOf(lgAll);
  RoundedRectangleBorder get xlShape => shapeOf(xlAll);

  /// Shape for buttons, chips and indicators: stadium unless [style] is
  /// square.
  OutlinedBorder get controlShape =>
      control >= NavisRadius.pill ? const StadiumBorder() : shapeOf(controlAll);

  // Matches Flutter's Theme.of(context) lookup convention for extensions.
  static NavisShapeData of(BuildContext context) {
    return Theme.of(context).extension<NavisShapeData>() ?? rounded;
  }

  @override
  NavisShapeData copyWith({
    NavisCornerStyle? style,
    double? xs,
    double? sm,
    double? md,
    double? lg,
    double? xl,
    double? control,
  }) {
    return NavisShapeData(
      style: style ?? this.style,
      xs: xs ?? this.xs,
      sm: sm ?? this.sm,
      md: md ?? this.md,
      lg: lg ?? this.lg,
      xl: xl ?? this.xl,
      control: control ?? this.control,
    );
  }

  @override
  NavisShapeData lerp(ThemeExtension<NavisShapeData>? other, double t) {
    if (other is! NavisShapeData) {
      return this;
    }
    double mix(double a, double b) => a + (b - a) * t;
    return NavisShapeData(
      style: t < 0.5 ? style : other.style,
      xs: mix(xs, other.xs),
      sm: mix(sm, other.sm),
      md: mix(md, other.md),
      lg: mix(lg, other.lg),
      xl: mix(xl, other.xl),
      control: mix(control, other.control),
    );
  }
}
