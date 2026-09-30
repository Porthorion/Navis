import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';

/// A release's custom icon in a circular disc, or a sparkles icon when the
/// release has none or its asset cannot be loaded.
class ChangelogReleaseIcon extends StatelessWidget {
  const ChangelogReleaseIcon({
    required this.version,
    required this.size,
    super.key,
    this.background,
    this.foreground,
  });

  final ChangelogVersion version;

  /// Diameter of the disc.
  final double size;

  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fg = foreground ?? colorScheme.onPrimaryContainer;
    final glyphSize = size * 0.56;
    final fallback = Icon(
      Icons.auto_awesome_outlined,
      key: const ValueKey<String>('changelogReleaseIconFallback'),
      size: glyphSize,
      color: fg,
    );
    final asset = version.iconAsset;

    Widget glyph;
    if (asset == null || asset.isEmpty) {
      glyph = fallback;
    } else if (asset.toLowerCase().endsWith('.svg')) {
      glyph = SvgPicture.asset(
        asset,
        width: glyphSize,
        height: glyphSize,
        errorBuilder: (_, _, _) => fallback,
      );
    } else {
      glyph = Image.asset(
        asset,
        width: glyphSize,
        height: glyphSize,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => fallback,
      );
    }

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background ?? colorScheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: ExcludeSemantics(child: glyph),
    );
  }
}
