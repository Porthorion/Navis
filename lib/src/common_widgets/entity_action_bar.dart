import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Playback actions for an album, playlist, artist or song collection.
///
/// The hierarchy is fixed so every collection reads the same way: Play is
/// the only filled action, Shuffle is tonal, and everything else
/// ([secondary]) is outlined. [compact] shows icon-only controls with the
/// same hierarchy for phones and narrow panes. Actions wrap onto further
/// rows with even spacing instead of overflowing.
class EntityActionBar extends StatelessWidget {
  const new({
    super.key,
    this.onPlay,
    this.onShuffle,
    this.secondary = const <Widget>[],
    this.compact = false,
    this.playKey,
    this.shuffleKey,
    this.showPlay = true,
    this.showShuffle = true,
  });

  /// Null disables Play while keeping it visible.
  final VoidCallback? onPlay;

  /// Null disables Shuffle while keeping it visible.
  final VoidCallback? onShuffle;

  /// Additional actions, usually [EntitySecondaryAction]s.
  final List<Widget> secondary;

  final bool compact;
  final Key? playKey;
  final Key? shuffleKey;
  final bool showPlay;
  final bool showShuffle;

  static const double _compactExtent = 48;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const iconConstraints = BoxConstraints(
      minWidth: _compactExtent,
      minHeight: _compactExtent,
    );
    return Wrap(
      spacing: NavisSpace.xs,
      runSpacing: NavisSpace.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (showPlay && compact)
          IconButton.filled(
            key: playKey,
            style: NavisColorStyleData.playStyleOf(context, circular: true),
            tooltip: l10n.albumDetailPlayAction,
            constraints: iconConstraints,
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded),
          )
        else if (showPlay)
          FilledButton.icon(
            key: playKey,
            style: NavisColorStyleData.playStyleOf(context),
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(l10n.albumDetailPlayAction),
          ),
        if (showShuffle && compact)
          IconButton.filledTonal(
            key: shuffleKey,
            style: NavisColorStyleData.tonalStyleOf(context, circular: true),
            tooltip: l10n.albumDetailShuffleAction,
            constraints: iconConstraints,
            onPressed: onShuffle,
            icon: const Icon(Icons.shuffle_rounded),
          )
        else if (showShuffle)
          FilledButton.tonalIcon(
            key: shuffleKey,
            style: NavisColorStyleData.tonalStyleOf(context),
            onPressed: onShuffle,
            icon: const Icon(Icons.shuffle_rounded),
            label: Text(l10n.albumDetailShuffleAction),
          ),
        ...secondary,
      ],
    );
  }
}

/// A secondary collection action (Download, More, Match, …) styled for
/// [EntityActionBar]: outlined with a label, or an outlined icon when
/// [compact].
class EntitySecondaryAction extends StatelessWidget {
  const new({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
    this.compact = false,
    this.tooltip,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final bool compact;

  /// Tooltip for the labelled form; the compact form always uses [label].
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      // Standard 40 px visual size (48 px tap target) so secondary icons
      // line up with labelled buttons and stay quieter than Play/Shuffle.
      return IconButton.outlined(
        tooltip: label,
        onPressed: onPressed,
        icon: icon,
      );
    }
    final button = OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon,
      label: Text(label),
    );
    final message = tooltip;
    return message == null ? button : Tooltip(message: message, child: button);
  }
}
