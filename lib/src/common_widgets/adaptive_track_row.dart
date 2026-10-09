import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_density_scope.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/utils/format_utils.dart';

class TrackRowModeScope extends InheritedWidget {
  const new({required this.mode, required super.child, super.key});
  final TrackRowMode mode;

  static TrackRowMode? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TrackRowModeScope>()?.mode;

  @override
  bool updateShouldNotify(TrackRowModeScope oldWidget) =>
      oldWidget.mode != mode;
}

/// Whether the enclosing track row is hovered or playing.
///
/// Desktop row actions stay quiet until their row is emphasized so dense
/// tables read as lists of songs rather than columns of icons.
class TrackRowEmphasisScope extends InheritedWidget {
  const new({required this.emphasized, required super.child, super.key});

  final bool emphasized;

  /// Null outside a shared track row, where actions keep full emphasis.
  static bool? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TrackRowEmphasisScope>()
      ?.emphasized;

  @override
  bool updateShouldNotify(TrackRowEmphasisScope oldWidget) =>
      oldWidget.emphasized != emphasized;
}

class _TrackRowHoverRegion extends StatefulWidget {
  const new({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  State<_TrackRowHoverRegion> createState() => _TrackRowHoverRegionState();
}

class _TrackRowHoverRegionState extends State<_TrackRowHoverRegion> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    opaque: false,
    onEnter: (_) => _setHovered(true),
    onExit: (_) => _setHovered(false),
    child: TrackRowEmphasisScope(
      emphasized: _hovered || widget.selected,
      child: widget.child,
    ),
  );
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

Widget _columns(List<Widget> children) {
  final flexes = switch (children.length) {
    3 => const [45, 25, 30],
    2 => const [65, 35],
    _ => List<int>.filled(children.length, 1),
  };
  return Row(
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(width: 12),
        Expanded(flex: flexes[i], child: children[i]),
      ],
    ],
  );
}

/// Presentation-only row; callers retain playback and occurrence ownership.
class AdaptiveTrackRow extends StatelessWidget {
  const new({
    required this.title,
    this.artist,
    this.album,
    this.duration,
    this.leading,
    this.leadingExtent,
    this.leadingGap = 12,
    this.actionExtent,
    this.actions,
    this.badge,
    this.isRemote = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.padding,
    this.showAlbumColumn = true,
    this.titleBadge,
    this.minHeight,
    super.key,
  });

  final String title;
  final String? artist;
  final String? album;
  final int? duration;
  final Widget? leading;

  /// Width of the leading slot; null follows the Density cover size.
  final double? leadingExtent;
  final double leadingGap;
  final double? actionExtent;
  final Widget? actions;
  final Widget? badge;
  final bool isRemote;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;

  /// Row padding; null follows the Density setting.
  final EdgeInsetsGeometry? padding;

  /// False on an album's own track list, where every row would repeat the
  /// same album name.
  final bool showAlbumColumn;

  /// A compact status shown after the title on the same line (for example
  /// "Not on server"), so it never adds a line to the row.
  final Widget? titleBadge;

  /// Rows sized for artwork follow the Density setting (64 comfortable, 52
  /// compact); numbered lists without artwork can be denser.
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = NavisDensityScope.of(context);
    final leadingExtent = this.leadingExtent ?? density.listCover;
    final padding = this.padding ?? density.trackRowPadding;
    final minHeight = this.minHeight ?? density.trackRowMinHeight;
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
            [artist, if (showAlbumColumn) album]
                .whereType<String>()
                .where((value) => value.trim().isNotEmpty)
                .join(' · '),
          TrackRowMode.medium => showAlbumColumn ? album ?? '' : '',
          TrackRowMode.wide => '',
        };
        // Without a secondary line the Remote badge rides on the title line,
        // so remote rows keep the height and title position of local rows.
        final remoteOnTitle = isRemote && secondary.isEmpty;
        final titleColumn = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: RemoteSourceMetadataLine(
                    isRemote: remoteOnTitle,
                    metadata: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: selected ? theme.colorScheme.primary : null,
                      ),
                    ),
                  ),
                ),
                if (titleBadge case final badge?) ...[
                  const SizedBox(width: 6),
                  Flexible(child: badge),
                ],
              ],
            ),
            if (secondary.isNotEmpty)
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
            : _columns([
                titleColumn,
                metadata(artist),
                if (mode == TrackRowMode.wide && showAlbumColumn)
                  metadata(album),
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
        // Column rows reserve at least the action width AdaptiveTrackHeader
        // reserves; otherwise narrower actions widen the flex columns and
        // every value drifts right of its heading. Wider actions keep their
        // natural width rather than overflowing.
        // Compact desktop rows reserve it too: one row's More button next to
        // another row's empty action would otherwise shift its Time.
        final Widget? actionWidget;
        if (actionExtent != null) {
          actionWidget = SizedBox(
            width: actionExtent,
            child: Align(alignment: Alignment.centerRight, child: actions),
          );
        } else if (actions != null &&
            (mode != TrackRowMode.compact ||
                resolveAdaptiveContextFor(context).desktopRuntime)) {
          actionWidget = ConstrainedBox(
            constraints: BoxConstraints(minWidth: estimatedActions),
            child: Align(
              alignment: Alignment.centerRight,
              widthFactor: 1,
              child: actions,
            ),
          );
        } else {
          actionWidget = actions;
        }
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
        final compactTitle = Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: selected ? theme.colorScheme.primary : null,
          ),
        );
        final rowInformation = compactMobile
            ? _CompactTrackInformation(
                title: compactTitle,
                status: titleBadge,
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
          child: _TrackRowHoverRegion(
            selected: selected,
            child: Material(
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: .08)
                  : Colors.transparent,
              borderRadius: NavisRadius.mdAll,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                onSecondaryTapDown: onSecondaryTapDown,
                borderRadius: NavisRadius.mdAll,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
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
          ),
        );
      },
    );
  }
}

/// Keeps duration with metadata when mobile controls crowd the title area.
class _CompactTrackInformation extends StatelessWidget {
  const new({
    required this.title,
    required this.secondary,
    required this.duration,
    required this.style,
    required this.isRemote,
    required this.badge,
    this.status,
  });

  final Widget title;

  /// The row's title badge. Narrow rows have no room for it beside the
  /// title, so it takes the duration's place on the metadata line (rows with
  /// a status have no song, hence no duration).
  final Widget? status;
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
                Theme.of(context).textTheme.labelSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
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
        final status = this.status;
        final separateDuration =
            status == null &&
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
                  if (status != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.6,
                      ),
                      child: status,
                    )
                  else
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
  const new({
    this.numberColumnExtent,
    this.leadingExtent,
    this.leadingGap = 12,
    this.actionExtent,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 8),
    this.showAlbumColumn = true,
    super.key,
  }) : assert(
         numberColumnExtent == null ||
             (numberColumnExtent > 0 &&
                 numberColumnExtent <= (leadingExtent ?? 40)),
         'Number column must fit inside the leading area.',
       );
  final double? numberColumnExtent;

  /// Width of the leading slot; null follows the Density cover size.
  final double? leadingExtent;
  final double leadingGap;
  final double? actionExtent;
  final EdgeInsetsGeometry padding;

  /// Must match the rows' [AdaptiveTrackRow.showAlbumColumn].
  final bool showAlbumColumn;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final leadingExtent =
          this.leadingExtent ?? NavisDensityScope.of(context).listCover;
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
              child: _columns([
                label(l10n.trackColumnTitle),
                label(l10n.trackColumnArtist),
                if (mode == TrackRowMode.wide && showAlbumColumn)
                  label(l10n.trackColumnAlbum),
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
