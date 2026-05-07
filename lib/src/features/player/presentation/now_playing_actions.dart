part of 'now_playing_screen.dart';

class _ActionRow extends ConsumerStatefulWidget {
  const _ActionRow({
    this.song,
    this.songId,
    this.isLiked = false,
    this.showLyrics = false,
    this.onLyricsToggle,
    this.wideEmbeddedMode = false,
    this.onOpenQueuePanel,
    this.onOpenSettingsPanel,
    this.onOpenSettingsSheet,
    this.onOpenMixPanel,
  });

  final SongsTableData? song;
  final String? songId;
  final bool isLiked;
  final bool showLyrics;
  final VoidCallback? onLyricsToggle;
  final bool wideEmbeddedMode;
  final VoidCallback? onOpenQueuePanel;
  final VoidCallback? onOpenSettingsPanel;
  final VoidCallback? onOpenSettingsSheet;
  final VoidCallback? onOpenMixPanel;

  @override
  ConsumerState<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends ConsumerState<_ActionRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _likeController;
  late final Animation<double> _likeScale;

  @override
  void initState() {
    super.initState();
    _likeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _likeScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1, end: 1.4), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.4, end: 1), weight: 60),
    ]).animate(CurvedAnimation(parent: _likeController, curve: Curves.easeOut));
  }

  @override
  void didUpdateWidget(_ActionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLiked != oldWidget.isLiked) {
      _likeController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _likeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final instantMix = ref.watch(instantMixProvider);
    final sameVibes = ref.watch(sameVibesProvider);
    final preferredMixMode = ref.watch(preferredMixModeProvider);
    final mixActive = preferredMixMode == PreferredMixMode.legacyInstantMix
        ? instantMix.active
        : sameVibes.active;
    final mixLoading = preferredMixMode == PreferredMixMode.legacyInstantMix
        ? (instantMix.refilling && instantMix.active)
        : (sameVibes.refilling && sameVibes.active);
    final colorScheme = Theme.of(context).colorScheme;

    final mixIcon = mixLoading
        ? SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: mixActive
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          )
        : Icon(
            mixActive ? Icons.explore : Icons.explore_outlined,
            color: mixActive
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          );

    final isRemote =
        widget.songId != null && !isServerAddressableSongId(widget.songId!);
    final legacyMixUnavailable =
        isRemote && preferredMixMode == PreferredMixMode.legacyInstantMix;

    final actionButtons = <Widget>[
      _NowPlayingActionButton(
        icon: Icon(
          Icons.queue_music_outlined,
          color: colorScheme.onSurfaceVariant,
        ),
        label: l10n.nowPlayingQueue,
        onTap: (widget.wideEmbeddedMode && widget.onOpenQueuePanel != null)
            ? widget.onOpenQueuePanel
            : () => NavService.showQueue(context, ref),
      ),
      _NowPlayingActionButton(
        icon: mixIcon,
        label: l10n.nowPlayingInstantMixLabel,
        isDisabled: legacyMixUnavailable,
        onTap: widget.songId == null
            ? null
            : legacyMixUnavailable
            ? () => showAppNotice(
                context,
                message: l10n.remoteSourceInstantMixUnavailable,
                level: AppNoticeLevel.error,
              )
            : () => unawaited(
                togglePreferredMixMode(ref, seedSongId: widget.songId!),
              ),
      ),
      _NowPlayingActionButton(
        icon: ScaleTransition(
          scale: _likeScale,
          child: Icon(
            widget.isLiked ? Icons.favorite : Icons.favorite_border,
            color: widget.isLiked
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
        ),
        label: widget.isLiked ? l10n.actionLiked : l10n.actionLike,
        isDisabled: isRemote,
        onTap: widget.songId == null
            ? null
            : isRemote
            ? () => showAppNotice(
                context,
                message: l10n.remoteSourceActionUnavailable,
                level: AppNoticeLevel.error,
              )
            : () {
                HapticFeedback.lightImpact();
                final handler = ref.read(audioHandlerProvider);
                handler?.toggleLike();
              },
      ),
      _NowPlayingActionButton(
        icon: Icon(
          widget.showLyrics ? Icons.lyrics : Icons.lyrics_outlined,
          color: widget.showLyrics
              ? colorScheme.primary
              : colorScheme.onSurfaceVariant,
        ),
        label: l10n.nowPlayingLyrics,
        onTap: widget.songId == null ? null : widget.onLyricsToggle,
      ),
      _NowPlayingActionButton(
        icon: Icon(
          Icons.settings_outlined,
          color: colorScheme.onSurfaceVariant,
        ),
        label: l10n.settingsTitle,
        onTap: () {
          if (widget.wideEmbeddedMode && widget.onOpenSettingsPanel != null) {
            widget.onOpenSettingsPanel!.call();
            return;
          }
          if (widget.onOpenSettingsSheet != null) {
            widget.onOpenSettingsSheet!.call();
            return;
          }
          _showNowPlayingSettingsSheet(context, ref, widget.song);
        },
      ),
    ];

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: actionButtons,
    );
  }
}

class _NowPlayingActionButton extends StatelessWidget {
  const _NowPlayingActionButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.isDisabled = false,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onTap;

  /// When true the button renders at 42 % opacity (greyed out) but [onTap]
  /// is still called if set — allowing an error snackbar to fire on tap.
  final bool isDisabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: (onTap == null || isDisabled) ? 0.42 : 1,
      child: IconButton(tooltip: label, onPressed: onTap, icon: icon),
    );
  }
}
