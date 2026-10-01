import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_tokens.dart';

class DesktopFrame extends StatelessWidget {
  const new({
    required this.layoutClass,
    required this.child,
    super.key,
    this.padding = const EdgeInsets.fromLTRB(20, 20, 20, 20),
  });

  final DesktopLayoutClass layoutClass;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Desktop pages use the full window width, matching Home.
    return Padding(padding: padding, child: child);
  }
}

class DesktopPanel extends StatelessWidget {
  const new({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(16),
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tokens = NavisTokens.of(context);
    return Material(
      color: color ?? colors.surfaceContainerLow,
      elevation: tokens.panelElevation,
      borderRadius: BorderRadius.circular(tokens.panelRadius),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

class DesktopSectionHeader extends StatelessWidget {
  const new({
    required this.title,
    super.key,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.only(bottom: 10),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null && subtitle!.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class DesktopListRow extends ConsumerWidget {
  const new({
    required this.title,
    super.key,
    this.leading,
    this.subtitle,
    this.subtitleWidget,
    this.trailing,
    this.onTap,
    this.onSecondaryTapDown,
    this.playbackSongId,
  }) : assert(
         subtitle == null || subtitleWidget == null,
         'Provide either subtitle or subtitleWidget, not both.',
       );

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;
  final Widget? trailing;
  final VoidCallback? onTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final String? playbackSongId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final tokens = NavisTokens.of(context);
    final playbackState = playbackSongId == null
        ? SongPlaybackIndicatorState.inactive
        : ref.watch(songPlaybackIndicatorStateProvider(playbackSongId!));
    final isSelected = playbackState.isSelected;
    final decoratedLeading = leading == null
        ? (isSelected ? SongPlaybackMarker(state: playbackState) : null)
        : ArtworkPlaybackMarker(state: playbackState, child: leading!);
    final row = Material(
      color: isSelected
          ? colors.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      borderRadius: NavisRadius.mdAll,
      child: InkWell(
        borderRadius: NavisRadius.mdAll,
        mouseCursor: onTap != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        hoverColor: colors.onSurface.withValues(alpha: tokens.hoverOpacity),
        highlightColor: colors.onSurface.withValues(alpha: tokens.hoverOpacity),
        splashColor: colors.onSurface.withValues(
          alpha: tokens.hoverOpacity * 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: <Widget>[
              if (decoratedLeading != null) ...<Widget>[
                decoratedLeading,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: isSelected
                          ? Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            )
                          : null,
                    ),
                    if (subtitle != null || subtitleWidget != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child:
                            subtitleWidget ??
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
    return SongPlaybackSemantics(state: playbackState, child: row);
  }
}
