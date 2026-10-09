import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:navis/src/theme/navis_theme.dart';

/// Displays the Navis logo in a theme-appropriate or accent colour.
///
/// The [size] parameter controls both width and height.
/// When [tintWithAccent] is true the icon is colorised with [tintColor] or
/// the theme's Navis brand accent (useful for the About screen).
class NavisIcon extends StatelessWidget {
  const new({
    super.key,
    this.size = 64,
    this.tintWithAccent = false,
    this.tintColor,
  });

  final double size;
  final bool tintWithAccent;
  final Color? tintColor;

  static const String assetPath = 'lib/src/icon/Navis_Logo.svg';

  @override
  Widget build(BuildContext context) {
    final color = tintWithAccent
        ? tintColor ?? NavisAccentColors.of(context).brand
        : Theme.of(context).colorScheme.onSurface;

    final image = SvgPicture.asset(
      assetPath,
      width: size,
      height: size,
      fit: BoxFit.contain,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );

    return ExcludeSemantics(child: image);
  }
}
