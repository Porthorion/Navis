import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/artwork_shape.dart';

/// A release's square "cover", shaped like album art.
///
/// It shows the release's own [ChangelogVersion.iconAsset] in the on-accent
/// colour on the accent colour when one is bundled. Otherwise, or when the
/// asset fails to load, it is a typographic cover: the version set large on
/// the accent colour.
class ChangelogReleaseCover extends ConsumerWidget {
  const new({required this.version, required this.size, super.key});

  final ChangelogVersion version;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final radius = artworkBorderRadius(
      ref.watch(coverArtShapeProvider),
      extent: size,
    );
    final colorScheme = Theme.of(context).colorScheme;
    final asset = version.iconAsset;
    final typographic = _TypographicCover(version: version, size: size);

    Widget cover;
    if (asset == null || asset.isEmpty) {
      cover = typographic;
    } else {
      final inset = size * 0.12;
      final artSize = size - inset * 2;
      // The icon is a single-colour glyph: only its shape is used, painted
      // like the typographic cover's text, so one file suits light and dark
      // themes and every accent colour.
      final ink = colorScheme.onPrimary;
      final art = asset.toLowerCase().endsWith('.svg')
          ? SvgPicture.asset(
              asset,
              width: artSize,
              height: artSize,
              colorFilter: ColorFilter.mode(ink, BlendMode.srcIn),
              errorBuilder: (_, _, _) => typographic,
            )
          : Image.asset(
              asset,
              width: artSize,
              height: artSize,
              fit: BoxFit.contain,
              color: ink,
              colorBlendMode: BlendMode.srcIn,
              errorBuilder: (_, _, _) => typographic,
            );
      cover = ColoredBox(
        key: const ValueKey<String>('changelogIconCover'),
        color: colorScheme.primary,
        child: Center(child: art),
      );
    }

    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox.square(dimension: size, child: cover),
      ),
    );
  }
}

class _TypographicCover extends StatelessWidget {
  const new({required this.version, required this.size});

  final ChangelogVersion version;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final pad = size * 0.08;
    // The wordmark is dropped on thumbnails, where it would be illegible.
    final showWordmark = size >= 72;

    return ColoredBox(
      key: const ValueKey<String>('changelogTypographicCover'),
      color: colorScheme.primary,
      child: Stack(
        children: <Widget>[
          if (showWordmark)
            Positioned(
              left: pad,
              top: pad * 0.8,
              child: Text(
                'Navis',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colorScheme.onPrimary,
                  fontSize: size * 0.1,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
            ),
          Positioned(
            left: pad * 0.7,
            right: pad,
            bottom: 0,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.bottomLeft,
              child: Text(
                version.displayVersion,
                maxLines: 1,
                style: theme.textTheme.displayLarge?.copyWith(
                  color: colorScheme.onPrimary,
                  fontSize: size * 0.44,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -size * 0.025,
                  height: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
