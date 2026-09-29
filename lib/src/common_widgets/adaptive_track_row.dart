import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/utils/format_utils.dart';

class TrackRowModeScope extends InheritedWidget {
  const TrackRowModeScope({
    required this.mode,
    required super.child,
    super.key,
  });
  final TrackRowMode mode;

  static TrackRowMode? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TrackRowModeScope>()?.mode;

  @override
  bool updateShouldNotify(TrackRowModeScope oldWidget) =>
      oldWidget.mode != mode;
}

double _durationWidth(BuildContext context) {
  final painter = TextPainter(
    text: TextSpan(
      text: '00:00:00',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width.ceilToDouble();
  painter.dispose();
  return width;
}

Widget _columns(TrackRowMode mode, List<Widget> children) => Row(
  children: [
    for (var i = 0; i < children.length; i++) ...[
      if (i > 0) const SizedBox(width: 12),
      Expanded(
        flex: mode == TrackRowMode.wide ? [45, 25, 30][i] : [65, 35][i],
        child: children[i],
      ),
    ],
  ],
);

/// Presentation-only row; callers retain playback and occurrence ownership.
class AdaptiveTrackRow extends StatelessWidget {
  const AdaptiveTrackRow({
    required this.title,
    this.artist,
    this.album,
    this.duration,
    this.leading,
    this.leadingExtent = 48,
    this.leadingGap = 12,
    this.actionExtent,
    this.actions,
    this.badge,
    this.isRemote = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    super.key,
  });

  final String title;
  final String? artist;
  final String? album;
  final int? duration;
  final Widget? leading;
  final double leadingExtent;
  final double leadingGap;
  final double? actionExtent;
  final Widget? actions;
  final Widget? badge;
  final bool isRemote;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = padding.resolve(Directionality.of(context));
        final width = (constraints.maxWidth - insets.horizontal).clamp(
          0.0,
          double.infinity,
        );
        final mode = ContentLayout.trackMode(
          width,
          MediaQuery.textScalerOf(context),
        );
        Widget metadata(String? value) => Text(
          value?.trim().isNotEmpty == true ? value! : '—',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
        final secondary = switch (mode) {
          TrackRowMode.compact =>
            [artist, album]
                .whereType<String>()
                .where((value) => value.trim().isNotEmpty)
                .join(' · '),
          TrackRowMode.medium => album ?? '',
          TrackRowMode.wide => '',
        };
        final titleColumn = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? theme.colorScheme.primary : null,
              ),
            ),
            if (secondary.isNotEmpty || isRemote)
              RemoteSourceMetadataLine(
                metadata: Text(
                  secondary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
                isRemote: isRemote,
              ),
            ?badge,
          ],
        );
        final information = mode == TrackRowMode.compact
            ? titleColumn
            : _columns(mode, [
                titleColumn,
                metadata(artist),
                if (mode == TrackRowMode.wide) metadata(album),
              ]);
        final durationWidget = SizedBox(
          width: _durationWidth(context),
          child: Text(
            formatSeconds(duration, showHours: true),
            textAlign: TextAlign.right,
            maxLines: 1,
            style: style?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );
        final estimatedActions =
            actionExtent ??
            (actions == null
                ? 0
                : mode == TrackRowMode.wide
                ? 144
                : 48);
        final availableMetadata =
            width -
            leadingExtent -
            leadingGap -
            _durationWidth(context) -
            20 -
            estimatedActions;
        final crowded =
            mode == TrackRowMode.compact &&
            (availableMetadata < 160 ||
                MediaQuery.textScalerOf(context).scale(14) > 18.2);
        final actionWidget = actionExtent == null
            ? actions
            : SizedBox(
                width: actionExtent,
                child: Align(alignment: Alignment.centerRight, child: actions),
              );
        final compactMobile =
            crowded && !resolveAdaptiveContextFor(context).desktopRuntime;
        final mobileTextWidth =
            width -
            leadingExtent -
            leadingGap -
            (actionWidget == null ? 0 : estimatedActions + 8);
        final stackControls = compactMobile
            ? mobileTextWidth < MediaQuery.textScalerOf(context).scale(96)
            : crowded;
        final rowInformation = compactMobile
            ? _CompactTrackInformation(
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: selected ? theme.colorScheme.primary : null,
                  ),
                ),
                secondary: secondary,
                duration: formatSeconds(duration, showHours: true),
                style: style,
                isRemote: isRemote,
                badge: badge,
              )
            : information;
        final body = Row(
          children: [
            SizedBox(width: leadingExtent, child: leading),
            SizedBox(width: leadingGap),
            Expanded(child: rowInformation),
            if (!stackControls && !compactMobile) ...[
              const SizedBox(width: 12),
              durationWidget,
              if (actionWidget != null) ...[
                const SizedBox(width: 8),
                actionWidget,
              ],
            ],
            if (!stackControls && compactMobile && actionWidget != null) ...[
              const SizedBox(width: 8),
              actionWidget,
            ],
          ],
        );
        return TrackRowModeScope(
          mode: mode,
          child: Material(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: .08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              onSecondaryTapDown: onSecondaryTapDown,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: padding,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: compactMobile
                        ? MainAxisAlignment.center
                        : MainAxisAlignment.start,
                    children: [
                      body,
                      if (stackControls)
                        Row(
                          children: [
                            if (!compactMobile) durationWidget,
                            const Spacer(),
                            ?actionWidget,
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Keeps duration with metadata when mobile controls crowd the title area.
class _CompactTrackInformation extends StatelessWidget {
  const _CompactTrackInformation({
    required this.title,
    required this.secondary,
    required this.duration,
    required this.style,
    required this.isRemote,
    required this.badge,
  });

  final Widget title;
  final String secondary;
  final String duration;
  final TextStyle? style;
  final bool isRemote;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final durationStyle = style?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    double measure(String text, TextStyle? textStyle) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final width = painter.width.ceilToDouble();
      painter.dispose();
      return width;
    }

    final durationWidth = measure(duration, durationStyle);
    final remoteWidth = isRemote
        ? measure(
                AppLocalizations.of(context)!.remoteSourceLabel,
                Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ) +
              22 // Globe, icon gap, and metadata gap.
        : 0.0;
    final durationLabel = Text(
      duration,
      textAlign: TextAlign.end,
      maxLines: 1,
      style: durationStyle,
    );
    final metadata = RemoteSourceMetadataLine(
      metadata: Text(
        secondary,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
      isRemote: isRemote,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final separateDuration =
            (secondary.isNotEmpty || isRemote) &&
            constraints.maxWidth - durationWidth - 8 - remoteWidth <
                MediaQuery.textScalerOf(context).scale(24);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title,
            if (separateDuration) ...[
              metadata,
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: durationLabel,
              ),
            ] else
              Row(
                children: [
                  Expanded(child: metadata),
                  const SizedBox(width: 8),
                  SizedBox(width: durationWidth, child: durationLabel),
                ],
              ),
            ?badge,
          ],
        );
      },
    );
  }
}

/// Column labels for full collections; short previews deliberately omit them.
class AdaptiveTrackHeader extends StatelessWidget {
  const AdaptiveTrackHeader({
    this.numberColumnExtent,
    this.leadingExtent = 48,
    this.leadingGap = 12,
    this.actionExtent,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 8),
    super.key,
  }) : assert(
         numberColumnExtent == null ||
             (numberColumnExtent > 0 && numberColumnExtent <= leadingExtent),
         'Number column must fit inside the leading area.',
       );
  final double? numberColumnExtent;
  final double leadingExtent;
  final double leadingGap;
  final double? actionExtent;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final insets = padding.resolve(Directionality.of(context));
      final mode = ContentLayout.trackMode(
        (constraints.maxWidth - insets.horizontal).clamp(0.0, double.infinity),
        MediaQuery.textScalerOf(context),
      );
      if (mode == TrackRowMode.compact) return const SizedBox.shrink();
      final l10n = AppLocalizations.of(context)!;
      Widget label(String text) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelMedium,
      );
      return Padding(
        padding: padding,
        child: Row(
          children: [
            SizedBox(
              width: leadingExtent + leadingGap,
              child: numberColumnExtent == null
                  ? null
                  : Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SizedBox(
                        width: numberColumnExtent,
                        child: Center(
                          child: Semantics(
                            header: true,
                            label: l10n.trackColumnNumberDescription,
                            excludeSemantics: true,
                            child: label(l10n.trackColumnNumber),
                          ),
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: _columns(mode, [
                label(l10n.trackColumnTitle),
                label(l10n.trackColumnArtist),
                if (mode == TrackRowMode.wide) label(l10n.trackColumnAlbum),
              ]),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: _durationWidth(context),
              child: Align(
                alignment: Alignment.centerRight,
                child: label(l10n.trackColumnDuration),
              ),
            ),
            SizedBox(
              width:
                  8 + (actionExtent ?? (mode == TrackRowMode.wide ? 144 : 48)),
            ),
          ],
        ),
      );
    },
  );
}
