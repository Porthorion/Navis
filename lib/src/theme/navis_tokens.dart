import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

/// Spacing scale shared by every layout.
///
/// Use these steps for padding and gaps instead of ad-hoc literals so rows,
/// headers and panels line up across screens.
abstract final class NavisSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Corner-radius scale shared by every surface.
///
/// Artwork follows the user's shape settings instead (see
/// `artworkBorderRadius`); these steps are for controls, rows, cards and
/// panels.
abstract final class NavisRadius {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;

  /// Fully rounded ends for pills, chips and circular controls.
  static const double pill = 999;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// Theme-dependent layout values and surface roles.
///
/// Values that do not vary by theme live in [NavisSpace] and [NavisRadius];
/// this extension carries the ones that do, such as OLED surface overrides.
@immutable
class NavisTokens extends ThemeExtension<NavisTokens> {
  const new({
    required this.frameMaxWidthCompact,
    required this.frameMaxWidthStandard,
    required this.frameMaxWidthUltraWide,
    required this.sidebarWidth,
    required this.panelRadius,
    required this.panelElevation,
    required this.hoverOpacity,
    required this.focusOpacity,
    required this.quietWarningContainer,
    required this.onQuietWarningContainer,
    required this.quietWarningAccent,
    required this.success,
  });

  /// Tokens for [scheme]. OLED keeps warnings off pure black by raising the
  /// container one step, matching its other container overrides. [style]
  /// supplies the colour style's success colour.
  factory forScheme(
    ColorScheme scheme, {
    bool oled = false,
    NavisColorStyleData? style,
    NavisCornerStyle corners = NavisCornerStyle.rounded,
  }) {
    // Panels follow the corner style's xl step.
    final panelRadius = NavisShapeData.forStyle(corners).xl;
    final warningBase = oled
        ? scheme.surfaceContainerHighest
        : scheme.surfaceContainerHigh;
    return NavisTokens(
      frameMaxWidthCompact: defaults.frameMaxWidthCompact,
      frameMaxWidthStandard: defaults.frameMaxWidthStandard,
      frameMaxWidthUltraWide: defaults.frameMaxWidthUltraWide,
      sidebarWidth: defaults.sidebarWidth,
      panelRadius: panelRadius,
      panelElevation: defaults.panelElevation,
      hoverOpacity: defaults.hoverOpacity,
      focusOpacity: defaults.focusOpacity,
      quietWarningContainer: Color.alphaBlend(
        scheme.error.withValues(alpha: 0.12),
        warningBase,
      ),
      onQuietWarningContainer: scheme.onSurface,
      quietWarningAccent: scheme.error,
      success:
          (style ??
                  NavisColorStyleData(
                    style: NavisColorStyle.neutral,
                    dark: scheme.brightness == Brightness.dark,
                  ))
              .success,
    );
  }

  final double frameMaxWidthCompact;
  final double frameMaxWidthStandard;
  final double frameMaxWidthUltraWide;
  final double sidebarWidth;
  final double panelRadius;
  final double panelElevation;
  final double hoverOpacity;
  final double focusOpacity;

  /// Background for recoverable, non-blocking problems such as a failed
  /// background sync: noticeable without out-shouting the content.
  final Color quietWarningContainer;
  final Color onQuietWarningContainer;

  /// Icon/accent colour paired with [quietWarningContainer].
  final Color quietWarningAccent;

  /// Foreground colour for confirmed, positive states such as a completed
  /// download or a successful connection test. Tuned for contrast on the
  /// scheme's surfaces; Material's [ColorScheme] has no success role.
  final Color success;

  static const NavisTokens defaults = NavisTokens(
    frameMaxWidthCompact: 1240,
    frameMaxWidthStandard: 1440,
    frameMaxWidthUltraWide: 1720,
    sidebarWidth: 300,
    panelRadius: NavisRadius.xl,
    panelElevation: 0,
    hoverOpacity: 0.09,
    focusOpacity: 0.14,
    quietWarningContainer: Color(0xFF2B2323),
    onQuietWarningContainer: Color(0xFFEDE0DE),
    quietWarningAccent: Color(0xFFFFB4AB),
    success: Color(0xFF81C995),
  );

  // Matches Flutter's Theme.of(context) lookup convention for extensions.
  // ignore: prefer_constructors_over_static_methods
  static NavisTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NavisTokens>() ??
        NavisTokens.forScheme(theme.colorScheme);
  }

  @override
  NavisTokens copyWith({
    double? frameMaxWidthCompact,
    double? frameMaxWidthStandard,
    double? frameMaxWidthUltraWide,
    double? sidebarWidth,
    double? panelRadius,
    double? panelElevation,
    double? hoverOpacity,
    double? focusOpacity,
    Color? quietWarningContainer,
    Color? onQuietWarningContainer,
    Color? quietWarningAccent,
    Color? success,
  }) {
    return NavisTokens(
      frameMaxWidthCompact: frameMaxWidthCompact ?? this.frameMaxWidthCompact,
      frameMaxWidthStandard:
          frameMaxWidthStandard ?? this.frameMaxWidthStandard,
      frameMaxWidthUltraWide:
          frameMaxWidthUltraWide ?? this.frameMaxWidthUltraWide,
      sidebarWidth: sidebarWidth ?? this.sidebarWidth,
      panelRadius: panelRadius ?? this.panelRadius,
      panelElevation: panelElevation ?? this.panelElevation,
      hoverOpacity: hoverOpacity ?? this.hoverOpacity,
      focusOpacity: focusOpacity ?? this.focusOpacity,
      quietWarningContainer:
          quietWarningContainer ?? this.quietWarningContainer,
      onQuietWarningContainer:
          onQuietWarningContainer ?? this.onQuietWarningContainer,
      quietWarningAccent: quietWarningAccent ?? this.quietWarningAccent,
      success: success ?? this.success,
    );
  }

  @override
  NavisTokens lerp(ThemeExtension<NavisTokens>? other, double t) {
    if (other is! NavisTokens) {
      return this;
    }
    double lerp(double a, double b) => a + (b - a) * t;
    Color lerpColor(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return NavisTokens(
      frameMaxWidthCompact: lerp(
        frameMaxWidthCompact,
        other.frameMaxWidthCompact,
      ),
      frameMaxWidthStandard: lerp(
        frameMaxWidthStandard,
        other.frameMaxWidthStandard,
      ),
      frameMaxWidthUltraWide: lerp(
        frameMaxWidthUltraWide,
        other.frameMaxWidthUltraWide,
      ),
      sidebarWidth: lerp(sidebarWidth, other.sidebarWidth),
      panelRadius: lerp(panelRadius, other.panelRadius),
      panelElevation: lerp(panelElevation, other.panelElevation),
      hoverOpacity: lerp(hoverOpacity, other.hoverOpacity),
      focusOpacity: lerp(focusOpacity, other.focusOpacity),
      quietWarningContainer: lerpColor(
        quietWarningContainer,
        other.quietWarningContainer,
      ),
      onQuietWarningContainer: lerpColor(
        onQuietWarningContainer,
        other.onQuietWarningContainer,
      ),
      quietWarningAccent: lerpColor(
        quietWarningAccent,
        other.quietWarningAccent,
      ),
      success: lerpColor(success, other.success),
    );
  }
}
