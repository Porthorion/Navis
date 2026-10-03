part of 'app_shell.dart';

class _DesktopMiniPlayerSurface extends ConsumerStatefulWidget {
  const new({
    required this.playback,
    required this.songTitle,
    required this.songArtist,
    required this.coverArtId,
    required this.coverArtUrl,
    required this.isExternalSource,
    required this.onBackInterceptorChanged,
    required this.onCompactWideOverlayActiveChanged,
    required this.onCompactWideQueueRequestChanged,
  });

  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isExternalSource;
  final ValueChanged<bool Function()?> onBackInterceptorChanged;
  final ValueChanged<bool> onCompactWideOverlayActiveChanged;
  final ValueChanged<VoidCallback?> onCompactWideQueueRequestChanged;

  @override
  ConsumerState<_DesktopMiniPlayerSurface> createState() =>
      _DesktopMiniPlayerSurfaceState();
}

class _DesktopMiniPlayerSurfaceState
    extends ConsumerState<_DesktopMiniPlayerSurface> {
  VoidCallback? _queueRequest;
  bool _embeddedOverlayActive = false;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(desktopWindowControllerProvider);
    final hasPlayback =
        widget.playback.isRadioMode ||
        (widget.playback.currentSongId ?? '').trim().isNotEmpty;

    return Material(
      key: const ValueKey<String>('desktopMiniPlayerSurface'),
      color: Theme.of(context).colorScheme.surface,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: hasPlayback
                ? LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth < 680 ||
                          constraints.maxHeight < 340) {
                        return _DesktopMiniPlayerTightPlayback(
                          playback: widget.playback,
                          songTitle: widget.songTitle,
                          songArtist: widget.songArtist,
                          coverArtId: widget.coverArtId,
                          coverArtUrl: widget.coverArtUrl,
                          isExternalSource: widget.isExternalSource,
                        );
                      }
                      return Center(
                        child: SizedBox(
                          width: math.min(constraints.maxWidth, 1200),
                          height: math.min(constraints.maxHeight, 720),
                          child: NowPlayingScreen(
                            wideEmbeddedMode: true,
                            compactWideLandscapeMode: true,
                            showEmbeddedVolumeBelowActions: true,
                            onShowQueue: () => _queueRequest?.call(),
                            onBackInterceptorChanged:
                                widget.onBackInterceptorChanged,
                            onCompactWideOverlayActiveChanged: (active) {
                              if (_embeddedOverlayActive != active) {
                                setState(() {
                                  _embeddedOverlayActive = active;
                                });
                              }
                              widget.onCompactWideOverlayActiveChanged(active);
                            },
                            onCompactWideQueueRequestChanged: (handler) {
                              _queueRequest = handler;
                              widget.onCompactWideQueueRequestChanged(handler);
                            },
                          ),
                        ),
                      );
                    },
                  )
                : const _DesktopMiniPlayerEmptyState(),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: AnimatedOpacity(
              key: const ValueKey<String>(
                'miniPlayerFloatingWindowControlsFade',
              ),
              opacity: _embeddedOverlayActive ? 0 : 1,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: IgnorePointer(
                ignoring: _embeddedOverlayActive,
                child: _DesktopMiniPlayerFloatingWindowControls(
                  controller: controller,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact, transparent edge controls sit in the top-right corner. They are
/// removed while an embedded panel is active so Queue, Lyrics, and settings
/// controls own their full surface.
class _DesktopMiniPlayerFloatingWindowControls extends StatelessWidget {
  const new({required this.controller});

  final DesktopWindowController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final alwaysOnTopAvailable = controller.supportsMiniAlwaysOnTop;
    final alwaysOnTopTooltip = !alwaysOnTopAvailable
        ? l10n.desktopMiniPlayerKeepOnTopUnavailable
        : controller.miniAlwaysOnTop
        ? l10n.desktopMiniPlayerStopOnTop
        : l10n.desktopMiniPlayerKeepOnTop;
    final iconButtonStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll<Size>(Size(28, 28)),
      maximumSize: const WidgetStatePropertyAll<Size>(Size(28, 28)),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.all(5),
      ),
      shape: const WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      // Keep hover/focus feedback on the glyph itself: a floating circular
      // ink background makes these intentionally lightweight edge actions
      // look heavier than the Mini Player's other controls.
      foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.onSurface.withValues(alpha: 0.38);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused) ||
            states.contains(WidgetState.pressed)) {
          return colors.primary;
        }
        return colors.onSurfaceVariant;
      }),
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    );

    return SafeArea(
      minimum: const EdgeInsets.all(2),
      bottom: false,
      child: Row(
        key: const ValueKey<String>('miniPlayerFloatingWindowControls'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Tooltip(
            message: alwaysOnTopTooltip,
            child: IconButton(
              key: const ValueKey<String>('miniPlayerAlwaysOnTop'),
              tooltip: null,
              isSelected: controller.miniAlwaysOnTop,
              style: iconButtonStyle,
              onPressed: !alwaysOnTopAvailable || controller.isApplyingMode
                  ? null
                  : () => unawaited(
                      controller.setMiniAlwaysOnTop(
                        !controller.miniAlwaysOnTop,
                      ),
                    ),
              icon: Icon(
                controller.miniAlwaysOnTop
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
              ),
            ),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: l10n.desktopReturnToView,
            child: IconButton(
              key: const ValueKey<String>('miniPlayerExitButton'),
              tooltip: null,
              style: iconButtonStyle,
              onPressed: controller.isApplyingMode
                  ? null
                  : () => unawaited(controller.setMiniPlayerMode(false)),
              icon: const Icon(Icons.open_in_full_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

enum _DesktopMiniPlayerAction {
  shuffle,
  repeat,
  speedPitch,
  equalizer,
  queue,
  lyrics,
}

class _DesktopMiniPlayerTightPlayback extends ConsumerWidget {
  const new({
    required this.playback,
    required this.songTitle,
    required this.songArtist,
    required this.coverArtId,
    required this.coverArtUrl,
    required this.isExternalSource,
  });

  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isExternalSource;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    // Only the seek slider below watches position ticks.
    final durationMs = playback.duration.inMilliseconds;
    final canSeek = !playback.isRadioMode && durationMs > 0;
    final title = (songTitle ?? '').trim().isEmpty
        ? l10n.miniPlayerUnknownTrack
        : songTitle!.trim();
    final artist = (songArtist ?? '').trim().isEmpty
        ? l10n.miniPlayerUnknownArtist
        : songArtist!.trim();

    Widget artwork;
    if ((coverArtId ?? '').trim().isNotEmpty) {
      artwork = CoverArtImage(
        coverArtId: coverArtId,
        size: kCoverArtStandardSize,
        width: 156,
        height: 156,
        shape: ArtworkShapeRole.cover,
        loadPriority: CoverArtLoadPriority.critical,
        isExternalSource: isExternalSource,
        remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
      );
    } else {
      artwork = _MiniRemoteArt(
        artUrl: coverArtUrl,
        colorScheme: colors,
        size: 156,
      );
    }

    Future<void> playPause() async {
      final handler = ref.read(audioHandlerProvider);
      if (playback.playing) {
        await handler?.pause();
      } else {
        await handler?.play();
      }
    }

    final shuffleOn = playback.shuffleMode == AudioServiceShuffleMode.all;
    final repeatActive = playback.repeatMode != AudioServiceRepeatMode.none;
    final repeatLabel = switch (playback.repeatMode) {
      AudioServiceRepeatMode.one => l10n.nowPlayingRepeatOne,
      AudioServiceRepeatMode.all ||
      AudioServiceRepeatMode.group => l10n.nowPlayingRepeatAll,
      AudioServiceRepeatMode.none => l10n.nowPlayingRepeatOff,
    };
    final eqSupported = ref.watch(eqCapabilitiesProvider).supported;

    void handleSecondaryAction(
      BuildContext menuContext,
      _DesktopMiniPlayerAction action,
    ) {
      final handler = ref.read(audioHandlerProvider);
      switch (action) {
        case _DesktopMiniPlayerAction.speedPitch:
          unawaited(showPlaybackAdjustmentQuickPanel(menuContext));
        case _DesktopMiniPlayerAction.equalizer:
          unawaited(showEqualizerQuickPanel(menuContext));
        case _DesktopMiniPlayerAction.shuffle:
          unawaited(
            handler?.setShuffleMode(
              playback.shuffleMode == AudioServiceShuffleMode.all
                  ? AudioServiceShuffleMode.none
                  : AudioServiceShuffleMode.all,
            ),
          );
        case _DesktopMiniPlayerAction.repeat:
          final next = switch (playback.repeatMode) {
            AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
            AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
            AudioServiceRepeatMode.one => AudioServiceRepeatMode.none,
            AudioServiceRepeatMode.group => AudioServiceRepeatMode.none,
          };
          unawaited(handler?.setRepeatMode(next));
        case _DesktopMiniPlayerAction.queue:
          Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const QueueScreen()));
        case _DesktopMiniPlayerAction.lyrics:
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const NowPlayingLyricsScreen(),
            ),
          );
      }
    }

    final transport = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (!playback.isRadioMode)
          IconButton(
            tooltip: l10n.nowPlayingPrevious,
            onPressed: () =>
                unawaited(ref.read(audioHandlerProvider)?.skipToPrevious()),
            icon: const Icon(Icons.skip_previous_rounded),
          ),
        IconButton.filled(
          tooltip: playback.playing
              ? l10n.nowPlayingPause
              : l10n.nowPlayingPlay,
          onPressed: () => unawaited(playPause()),
          icon: _remoteLoadingPlayPauseIcon(
            isExternalSource: isExternalSource,
            playback: playback,
            isPlaying: playback.playing,
            loadingColor: Theme.of(context).colorScheme.onPrimary,
          ),
        ),
        IconButton(
          tooltip: playback.isRadioMode
              ? l10n.radioStopStation
              : l10n.nowPlayingNext,
          onPressed: () => unawaited(
            playback.isRadioMode
                ? ref.read(audioHandlerProvider)?.stopRadio()
                : ref.read(audioHandlerProvider)?.skipToNext(),
          ),
          icon: Icon(
            playback.isRadioMode ? Icons.stop_rounded : Icons.skip_next_rounded,
          ),
        ),
        Builder(
          builder: (menuContext) => PopupMenuButton<_DesktopMiniPlayerAction>(
            key: const ValueKey<String>('desktopMiniPlayerMoreButton'),
            tooltip: l10n.nowPlayingMore,
            onSelected: (action) => handleSecondaryAction(menuContext, action),
            itemBuilder: (context) =>
                <PopupMenuEntry<_DesktopMiniPlayerAction>>[
                  if (!playback.isRadioMode) ...[
                    _miniPlayerMenuItem(
                      context,
                      action: _DesktopMiniPlayerAction.shuffle,
                      icon: Icons.shuffle,
                      label: shuffleOn
                          ? l10n.nowPlayingShuffle
                          : l10n.nowPlayingShuffleOff,
                      active: shuffleOn,
                    ),
                    _miniPlayerMenuItem(
                      context,
                      action: _DesktopMiniPlayerAction.repeat,
                      icon: playback.repeatMode == AudioServiceRepeatMode.one
                          ? Icons.repeat_one
                          : Icons.repeat,
                      label: repeatLabel,
                      active: repeatActive,
                    ),
                    _miniPlayerMenuItem(
                      context,
                      action: _DesktopMiniPlayerAction.speedPitch,
                      icon: Icons.speed,
                      label: l10n.desktopMiniPlayerSpeedPitchAction,
                    ),
                  ],
                  if (eqSupported)
                    _miniPlayerMenuItem(
                      context,
                      action: _DesktopMiniPlayerAction.equalizer,
                      icon: Icons.equalizer,
                      label: l10n.eqTitle,
                    ),
                  if (!playback.isRadioMode) ...[
                    _miniPlayerMenuItem(
                      context,
                      action: _DesktopMiniPlayerAction.queue,
                      icon: Icons.queue_music_rounded,
                      label: l10n.nowPlayingQueue,
                    ),
                    _miniPlayerMenuItem(
                      context,
                      action: _DesktopMiniPlayerAction.lyrics,
                      icon: Icons.lyrics_outlined,
                      label: l10n.nowPlayingLyrics,
                    ),
                  ],
                ],
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ),
      ],
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          key: const ValueKey<String>('desktopMiniPlayerTightPlayback'),
          padding: const EdgeInsets.fromLTRB(16, 56, 16, 8),
          child: Row(
            children: <Widget>[
              Flexible(child: AspectRatio(aspectRatio: 1, child: artwork)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      key: const ValueKey<String>('desktopMiniPlayerTitle'),
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      key: const ValueKey<String>('desktopMiniPlayerArtist'),
                      artist,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                    if (isExternalSource)
                      const Align(
                        alignment: Alignment.center,
                        child: RemoteSourceIndicator(
                          variant: RemoteSourceIndicatorVariant.inline,
                        ),
                      ),
                    if (playback.isRadioMode)
                      Align(
                        alignment: Alignment.center,
                        child: Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.podcasts_rounded, size: 16),
                          label: Text(l10n.radioLive),
                        ),
                      )
                    else
                      RepaintBoundary(
                        child: Consumer(
                          builder: (context, ref, _) {
                            final position =
                                ref
                                    .watch(playbackPositionProvider)
                                    .asData
                                    ?.value ??
                                playback.position;
                            return Slider(
                              key: const ValueKey<String>(
                                'desktopMiniPlayerSeekSlider',
                              ),
                              value: canSeek
                                  ? position.inMilliseconds
                                        .clamp(0, durationMs)
                                        .toDouble()
                                  : 0.0,
                              max: canSeek ? durationMs.toDouble() : 1,
                              onChanged: canSeek
                                  ? (value) => unawaited(
                                      ref
                                          .read(audioHandlerProvider)
                                          ?.seek(
                                            Duration(
                                              milliseconds: value.round(),
                                            ),
                                          ),
                                    )
                                  : null,
                            );
                          },
                        ),
                      ),
                    transport,
                    const _DesktopMiniPlayerInlineVolumeControl(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopMiniPlayerUndersizedSurface extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey<String>('desktopMiniPlayerUndersized'),
      color: colors.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.picture_in_picture_alt_rounded,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.desktopMiniPlayerTooSmallTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.desktopMiniPlayerTooSmallDescription,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopMiniPlayerInlineVolumeControl extends ConsumerWidget {
  const new();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final volume = ref.watch(playbackVolumeProvider);
    return SizedBox(
      key: const ValueKey<String>('desktopMiniPlayerVolumeSlider'),
      height: 44,
      child: DesktopVolumeSlider(
        volume: volume,
        compact: true,
        expanded: true,
        semanticLabel: l10n.playbackVolumeSemanticLabel,
        muteTooltip: l10n.playbackMuteTooltip,
        unmuteTooltip: l10n.playbackUnmuteTooltip,
        onMuteToggle: () =>
            unawaited(ref.read(playbackVolumeProvider.notifier).toggleMute()),
        onChanged: (value) => unawaited(
          ref.read(playbackVolumeProvider.notifier).setVolume(value),
        ),
        onChangeEnd: (value) => unawaited(
          ref
              .read(playbackVolumeProvider.notifier)
              .setVolume(value, persistImmediately: true),
        ),
      ),
    );
  }
}

class _DesktopMiniPlayerEmptyState extends ConsumerWidget {
  const new();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final volume = ref.watch(playbackVolumeProvider);
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.music_note_rounded,
                  size: 64,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(height: 14),
                Text(
                  l10n.desktopNothingPlaying,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.desktopNothingPlayingPrompt,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: 280,
                  child: DesktopVolumeSlider(
                    key: const ValueKey<String>(
                      'desktopMiniPlayerVolumeSlider',
                    ),
                    volume: volume,
                    semanticLabel: l10n.playbackVolumeSemanticLabel,
                    muteTooltip: l10n.playbackMuteTooltip,
                    unmuteTooltip: l10n.playbackUnmuteTooltip,
                    onMuteToggle: () => unawaited(
                      ref.read(playbackVolumeProvider.notifier).toggleMute(),
                    ),
                    onChanged: (value) => unawaited(
                      ref
                          .read(playbackVolumeProvider.notifier)
                          .setVolume(value),
                    ),
                    onChangeEnd: (value) => unawaited(
                      ref
                          .read(playbackVolumeProvider.notifier)
                          .setVolume(value, persistImmediately: true),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopWindowTransitionGate extends ConsumerWidget {
  const new({required this.mode, required this.request});

  final DesktopWindowMode mode;
  final DesktopWindowTransitionRequest? request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(desktopWindowControllerProvider);
    final l10n = AppLocalizations.of(context)!;
    final enteringMini = mode == DesktopWindowMode.desktop;
    final workArea = controller.currentWorkArea;
    final desktopAvailable =
        workArea == null || supportsDesktopView(workArea.size);

    Future<void> restoreCurrentMode() {
      return controller.resolveTransition(switchMode: false);
    }

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 500;
        final outerInset = compact ? 8.0 : 24.0;
        final innerInset = compact ? 14.0 : 24.0;
        final availableHeight = math.max<double>(
          0,
          constraints.maxHeight - (outerInset * 2),
        );

        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(outerInset),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: availableHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Card(
                    elevation: 8,
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: EdgeInsets.all(innerInset),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            enteringMini
                                ? Icons.picture_in_picture_alt_rounded
                                : Icons.desktop_windows_rounded,
                            size: compact ? 34 : 44,
                          ),
                          SizedBox(height: compact ? 6 : 16),
                          Text(
                            enteringMini
                                ? l10n.desktopWindowTooSmallTitle
                                : l10n.desktopReturnQuestion,
                            textAlign: TextAlign.center,
                            style:
                                (compact
                                        ? Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                        : Theme.of(context)
                                              .textTheme
                                              .titleLarge)
                                    ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          SizedBox(height: compact ? 4 : 8),
                          Text(
                            enteringMini && !desktopAvailable
                                ? l10n.desktopViewUnavailableOnDisplay
                                : enteringMini
                                ? l10n.desktopWindowMinimumDescription
                                : l10n.desktopReturnDescription,
                            textAlign: TextAlign.center,
                            style: compact
                                ? Theme.of(context).textTheme.bodySmall
                                : null,
                          ),
                          SizedBox(height: compact ? 10 : 20),
                          if (request == null)
                            const CircularProgressIndicator()
                          else
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 260),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  FilledButton(
                                    autofocus: true,
                                    onPressed:
                                        controller.isApplyingMode ||
                                            (!enteringMini && !desktopAvailable)
                                        ? null
                                        : () => unawaited(
                                            controller.resolveTransition(
                                              switchMode: true,
                                            ),
                                          ),
                                    child: Text(
                                      enteringMini
                                          ? l10n.desktopSwitchToMiniPlayer
                                          : l10n.desktopReturnToView,
                                    ),
                                  ),
                                  SizedBox(height: compact ? 4 : 8),
                                  OutlinedButton(
                                    onPressed:
                                        controller.isApplyingMode ||
                                            (enteringMini && !desktopAvailable)
                                        ? null
                                        : () => unawaited(restoreCurrentMode()),
                                    child: Text(
                                      enteringMini
                                          ? l10n.desktopRestoreSize
                                          : l10n.desktopKeepMiniPlayer,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    return RepaintBoundary(
      key: const ValueKey<String>('desktopWindowTransitionGate'),
      child: PopScope(
        canPop: false,
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (request != null && (!enteringMini || desktopAvailable)) {
                unawaited(restoreCurrentMode());
              }
            },
          },
          child: Focus(
            autofocus: true,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.scrim
                  .withValues(alpha: 0.72),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// A Mini Player overflow entry whose icon is tinted while its mode is on, so
/// shuffle and repeat show their current state rather than a fixed label.
PopupMenuItem<_DesktopMiniPlayerAction> _miniPlayerMenuItem(
  BuildContext context, {
  required _DesktopMiniPlayerAction action,
  required IconData icon,
  required String label,
  bool active = false,
}) {
  final primary = Theme.of(context).colorScheme.primary;
  return PopupMenuItem<_DesktopMiniPlayerAction>(
    key: ValueKey<String>('desktopMiniPlayerMenu-${action.name}'),
    value: action,
    child: Row(
      children: <Widget>[
        Icon(icon, size: 20, color: active ? primary : null),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            label,
            style: active ? TextStyle(color: primary) : null,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}
