part of 'app_shell.dart';

class _DesktopLyricsOverlay extends ConsumerWidget {
  const _DesktopLyricsOverlay({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final playback = ref.watch(playerStateProvider);
    final songId = playback.currentSongId;
    final position =
        ref.watch(playbackPositionProvider).asData?.value ?? playback.position;

    return Material(
      color: colors.surface,
      child: Column(
        children: <Widget>[
          // ── Header bar ──────────────────────────────────────────────
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
              child: Row(
                children: <Widget>[
                  Icon(Icons.lyrics_outlined, color: colors.primary, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    l10n.nowPlayingLyrics,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
          // ── Lyrics content ──────────────────────────────────────────
          Expanded(
            child: songId == null || songId.trim().isEmpty
                ? Center(
                    child: Text(
                      l10n.lyricsNoneAvailable,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colors.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  )
                : _DesktopLyricsContent(songId: songId, position: position),
          ),
        ],
      ),
    );
  }
}

class _DesktopLyricsContent extends ConsumerWidget {
  const _DesktopLyricsContent({required this.songId, required this.position});

  final String songId;
  final Duration position;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final lyricsAsync = ref.watch(lyricsProvider(songId));

    return lyricsAsync.when(
      data: (resolution) => LyricsDisplayWidget(
        lyrics: resolution.lyrics,
        currentPosition: position,
        onSeek: (seekPosition) {
          unawaited(ref.read(audioHandlerProvider)?.seek(seekPosition));
        },
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) {
        final message = l10n.lyricsNoneAvailable;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                message,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colors.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => ref.invalidate(lyricsProvider(songId)),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.commonRetry),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Animates the bottom player sheet in/out with a slide-from-bottom transition.
///
/// When [showPlayer] transitions to `true`, the child slides up from below
/// the viewport. When it transitions to `false`, the child slides back down
/// and is then removed from the tree.
class _SlideUpPlayerTransition extends StatefulWidget {
  const _SlideUpPlayerTransition({
    required this.showPlayer,
    required this.child,
  });

  final bool showPlayer;
  final Widget child;

  @override
  State<_SlideUpPlayerTransition> createState() =>
      _SlideUpPlayerTransitionState();
}

class _SlideUpPlayerTransitionState extends State<_SlideUpPlayerTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  Widget? _presentedChild;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 220),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.addStatusListener(_handleAnimationStatus);
    if (widget.showPlayer) {
      _controller.value = 1.0;
      _presentedChild = widget.child;
    }
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed ||
        widget.showPlayer ||
        _presentedChild == null ||
        !mounted) {
      return;
    }
    setState(() {
      _presentedChild = null;
    });
  }

  @override
  void didUpdateWidget(_SlideUpPlayerTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showPlayer) {
      _presentedChild = widget.child;
      if (!oldWidget.showPlayer) {
        _controller.forward();
      }
    } else if (oldWidget.showPlayer) {
      _presentedChild = oldWidget.child;
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleAnimationStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final child = _presentedChild;
        if (child == null) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          left: 0,
          child: IgnorePointer(
            key: const ValueKey<String>('playerExitIgnorePointer'),
            ignoring: !widget.showPlayer,
            child: SlideTransition(position: _slideAnimation, child: child),
          ),
        );
      },
    );
  }
}
