import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:navis/src/theme/navis_theme.dart';

/// Displays the Navis app icon, automatically switching between dark and light
/// variants based on the current theme brightness.
///
/// The [size] parameter controls both width and height.
/// When [tintWithAccent] is true the icon is colorised with [tintColor] or
/// the theme's Navis brand accent (useful for the About screen).
class NavisIcon extends StatelessWidget {
  const NavisIcon({
    super.key,
    this.size = 64,
    this.tintWithAccent = false,
    this.tintColor,
  });

  final double size;
  final bool tintWithAccent;
  final Color? tintColor;

  static const String _darkAsset = 'lib/src/icon/Navis_Icon_Dark.svg';
  static const String _lightAsset = 'lib/src/icon/Navis_Icon_Light.svg';

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    // Dark icon is used on light backgrounds, light icon on dark backgrounds.
    final asset = brightness == Brightness.dark ? _lightAsset : _darkAsset;

    final image = SvgPicture.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      colorFilter: tintWithAccent
          ? ColorFilter.mode(
              tintColor ?? NavisAccentColors.of(context).brand,
              BlendMode.srcATop,
            )
          : null,
    );

    return ExcludeSemantics(child: image);
  }
}
