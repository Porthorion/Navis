import 'package:flutter/material.dart';

/// Displays the Navis app icon, automatically switching between dark and light
/// variants based on the current theme brightness.
///
/// The [size] parameter controls both width and height.
/// When [tintWithAccent] is true the icon is colorised with the theme's
/// primary colour (useful for the About screen).
class NavisIcon extends StatelessWidget {
  const NavisIcon({
    super.key,
    this.size = 64,
    this.tintWithAccent = false,
  });

  final double size;
  final bool tintWithAccent;

  static const String _darkAsset = 'lib/src/icon/Navis_Icon_dark.png';
  static const String _lightAsset = 'lib/src/icon/Navis_Icon_light.png';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    // Dark icon is used on light backgrounds, light icon on dark backgrounds.
    final asset = brightness == Brightness.dark ? _lightAsset : _darkAsset;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final decodeSize = (size * devicePixelRatio).round().clamp(24, 384);

    final image = Image.asset(
      asset,
      width: size,
      height: size,
      cacheWidth: decodeSize,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      color: tintWithAccent ? colorScheme.primary : null,
      colorBlendMode: tintWithAccent ? BlendMode.srcATop : null,
    );

    return ExcludeSemantics(child: image);
  }
}
