import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_tooltip.dart';

enum RemoteSourceIndicatorVariant { artwork, compactArtwork, inline, chip }

enum RemoteSourceIndicatorPolicy { automatic, hidden }

/// Keeps provenance on the same visual line as descriptive metadata.
///
/// The metadata remains flexible so long artist/album text truncates before
/// the fixed-width Remote label, without changing the height of otherwise
/// identical local and remote rows.
class RemoteSourceMetadataLine extends StatelessWidget {
  const RemoteSourceMetadataLine({
    required this.metadata,
    required this.isRemote,
    super.key,
    this.spacing = 6,
  });

  final Widget metadata;
  final bool isRemote;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (!isRemote) return metadata;
    return Row(
      children: <Widget>[
        Flexible(child: metadata),
        SizedBox(width: spacing),
        const RemoteSourceIndicator(
          variant: RemoteSourceIndicatorVariant.inline,
        ),
      ],
    );
  }
}

class RemoteSourceIndicator extends StatelessWidget {
  const RemoteSourceIndicator({
    required this.variant,
    super.key,
  });

  static const semanticsKey = ValueKey<String>('remote-source-indicator');
  static const tooltipKey = ValueKey<String>('remote-source-tooltip');

  final RemoteSourceIndicatorVariant variant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final semanticLabel = l10n.externalSourceBadgeLabel;
    return Semantics(
      key: semanticsKey,
      label: semanticLabel,
      tooltip: semanticLabel,
      container: true,
      child: NavisTooltip(
        message: semanticLabel,
        excludeFromSemantics: true,
        enableLongPress: false,
        bubbleKey: tooltipKey,
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: switch (variant) {
              RemoteSourceIndicatorVariant.artwork => _ArtworkIndicator(
                label: l10n.remoteSourceLabel,
              ),
              RemoteSourceIndicatorVariant.compactArtwork =>
                const _CompactArtworkIndicator(),
              RemoteSourceIndicatorVariant.inline => _InlineIndicator(
                label: l10n.remoteSourceLabel,
              ),
              RemoteSourceIndicatorVariant.chip => _ChipIndicator(
                label: l10n.remoteSourceLabel,
              ),
            },
          ),
        ),
      ),
    );
  }
}

class RemoteSourceArtworkOverlay extends StatelessWidget {
  const RemoteSourceArtworkOverlay({
    required this.child,
    required this.isRemote,
    super.key,
    this.policy = RemoteSourceIndicatorPolicy.automatic,
    this.width,
    this.height,
  });

  final Widget child;
  final bool isRemote;
  final RemoteSourceIndicatorPolicy policy;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    if (!isRemote || policy == RemoteSourceIndicatorPolicy.hidden) {
      return child;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final explicitWidth = _finitePositive(width);
        final explicitHeight = _finitePositive(height);
        final constrainedWidth = constraints.hasBoundedWidth
            ? _finitePositive(constraints.maxWidth)
            : null;
        final constrainedHeight = constraints.hasBoundedHeight
            ? _finitePositive(constraints.maxHeight)
            : null;
        final resolvedWidth = explicitWidth ?? constrainedWidth;
        final resolvedHeight = explicitHeight ?? constrainedHeight;
        final extent = resolvedWidth == null
            ? resolvedHeight
            : resolvedHeight == null
            ? resolvedWidth
            : resolvedWidth < resolvedHeight
            ? resolvedWidth
            : resolvedHeight;
        final showLabel = extent != null && extent >= 96;
        return Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: <Widget>[
            child,
            Positioned(
              top: showLabel ? 6 : 4,
              left: showLabel ? 6 : 4,
              child: RemoteSourceIndicator(
                variant: showLabel
                    ? RemoteSourceIndicatorVariant.artwork
                    : RemoteSourceIndicatorVariant.compactArtwork,
              ),
            ),
          ],
        );
      },
    );
  }

  static double? _finitePositive(double? value) {
    if (value == null || !value.isFinite || value <= 0) return null;
    return value;
  }
}

class _ArtworkIndicator extends StatelessWidget {
  const _ArtworkIndicator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.90),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.72),
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x52000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.public_rounded, size: 13, color: colors.onSurface),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactArtworkIndicator extends StatelessWidget {
  const _CompactArtworkIndicator();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.90),
        shape: BoxShape.circle,
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.72),
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x52000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(Icons.public_rounded, size: 12, color: colors.onSurface),
      ),
    );
  }
}

class _InlineIndicator extends StatelessWidget {
  const _InlineIndicator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.public_rounded, size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          label,
          maxLines: 1,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _ChipIndicator extends StatelessWidget {
  const _ChipIndicator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.public_rounded,
              size: 14,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
