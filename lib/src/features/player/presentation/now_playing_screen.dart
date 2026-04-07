import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/features/player/presentation/desktop_volume_slider.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/common_widgets/rating_widget.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/domain/set_rating.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/utils/song_id_utils.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/format_utils.dart';

/// Splits a combined artist string into individual artist names.
/// Mirrors the same function in app_shell.dart.
List<String> _splitArtists(String raw) {
  final patterns = [
    RegExp(r'\s*;\s*'),
    RegExp(r'\s+feat(?:uring)?\.?\s+', caseSensitive: false),
    RegExp(r'\s+ft\.\s+', caseSensitive: false),
    RegExp(r'\s+/\s+'), // space-slash-space only — preserves K/DA, AC/DC
  ];
  List<String> parts = [raw.trim()];
  for (final pat in patterns) {
    parts = parts.expand((p) => p.split(pat)).toList();
  }
  return parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
}

/// A single artist entry for [_TrackInfo.artistLinks].
typedef _ArtistLink = ({String name, VoidCallback? onTap});

String _formatDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

Widget _songSwapTransitionBuilder(Widget child, Animation<double> animation) {
  final curved = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return FadeTransition(
    opacity: curved,
    child: ScaleTransition(
      scale: Tween<double>(begin: 0.985, end: 1).animate(curved),
      child: child,
    ),
  );
}

Widget _songSwapArtDirectionalTransitionBuilder(
  Widget child,
  Animation<double> animation, {
  required ManualTrackChangeDirection direction,
}) {
  // Manual direction semantics:
  // next => old art exits left, new art enters from right.
  // previous => old art exits right, new art enters from left.
  // Use full-width travel so artwork moves fully off-screen.
  const slideDistance = 1.0;
  final incomingBeginX = switch (direction) {
    ManualTrackChangeDirection.next => slideDistance,
    ManualTrackChangeDirection.previous => -slideDistance,
  };
  final outgoingEndX = switch (direction) {
    ManualTrackChangeDirection.next => -slideDistance,
    ManualTrackChangeDirection.previous => slideDistance,
  };

  final isOutgoing =
      animation.status == AnimationStatus.reverse ||
      animation.status == AnimationStatus.dismissed;

  // Sequence the transition to avoid visual "stacking":
  // old art moves out first, then new art moves in.
  const outgoingWindow = Interval(0, 0.5, curve: Curves.easeInCubic);
  const incomingWindow = Interval(0.5, 1, curve: Curves.easeOutCubic);

  if (isOutgoing) {
    final curvedOut = CurvedAnimation(
      parent: ReverseAnimation(animation),
      curve: outgoingWindow,
    );
    return ScaleTransition(
      scale: Tween<double>(begin: 1, end: 0.82).animate(curvedOut),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset.zero,
          end: Offset(outgoingEndX, 0),
        ).animate(curvedOut),
        child: child,
      ),
    );
  }

  final curvedIn = CurvedAnimation(parent: animation, curve: incomingWindow);
  return ScaleTransition(
    scale: Tween<double>(begin: 0.84, end: 1).animate(curvedIn),
    child: SlideTransition(
      position: Tween<Offset>(
        begin: Offset(incomingBeginX, 0),
        end: Offset.zero,
      ).animate(curvedIn),
      child: child,
    ),
  );
}

Widget _coverArtSwitcherLayoutBuilder(
  Widget? currentChild,
  List<Widget> previousChildren,
) {
  return ClipRect(
    child: Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        ...previousChildren,
        ...?switch (currentChild) {
          null => null,
          final child => <Widget>[child],
        },
      ],
    ),
  );
}

Widget _identityTransitionBuilder(Widget child, Animation<double> animation) {
  return child;
}

final Map<String, Color> _nowPlayingTintColorCache = <String, Color>{};
final Map<String, Future<void>> _nowPlayingVisualPrewarmInflight =
    <String, Future<void>>{};

String? nowPlayingVisualCacheKeyFor({
  required Brightness brightness,
  String? coverArtId,
  String? artUrl,
}) {
  final trimmedCoverArtId = coverArtId?.trim() ?? '';
  if (trimmedCoverArtId.isNotEmpty) {
    return 'id:$trimmedCoverArtId|b:${brightness.name}';
  }
  final trimmedArtUrl = artUrl?.trim() ?? '';
  if (trimmedArtUrl.isNotEmpty) {
    return 'url:$trimmedArtUrl|b:${brightness.name}';
  }
  return null;
}

Color? nowPlayingCachedTintColor({
  required Brightness brightness,
  String? coverArtId,
  String? artUrl,
}) {
  final key = nowPlayingVisualCacheKeyFor(
    brightness: brightness,
    coverArtId: coverArtId,
    artUrl: artUrl,
  );
  if (key == null) {
    return null;
  }
  return _nowPlayingTintColorCache[key];
}

ImageProvider<Object>? _resolveNowPlayingImageProvider({
  required WidgetRef ref,
  String? coverArtId,
  String? artUrl,
}) {
  final cacheManager = ref.read(coverArtCacheManagerProvider).asData?.value;
  final trimmedCoverArtId = coverArtId?.trim() ?? '';
  if (trimmedCoverArtId.isNotEmpty) {
    final api = ref.read(subsonicApiProvider);
    if (api == null) {
      return null;
    }
    final coverUrl = api.getCoverArtUrl(id: trimmedCoverArtId, size: 768);
    return cacheManager == null
        ? NetworkImage(coverUrl.toString())
        : CachedNetworkImageProvider(
            coverUrl.toString(),
            cacheManager: cacheManager,
          );
  }

  final trimmedArtUrl = artUrl?.trim() ?? '';
  if (trimmedArtUrl.isEmpty) {
    return null;
  }
  return cacheManager == null
      ? NetworkImage(trimmedArtUrl)
      : CachedNetworkImageProvider(trimmedArtUrl, cacheManager: cacheManager);
}

Future<void> prewarmNowPlayingVisuals({
  required BuildContext context,
  required WidgetRef ref,
  required Brightness brightness,
  String? coverArtId,
  String? artUrl,
}) async {
  final cacheKey = nowPlayingVisualCacheKeyFor(
    brightness: brightness,
    coverArtId: coverArtId,
    artUrl: artUrl,
  );
  if (cacheKey == null) {
    return;
  }
  if (_nowPlayingTintColorCache.containsKey(cacheKey)) {
    return;
  }
  final inflight = _nowPlayingVisualPrewarmInflight[cacheKey];
  if (inflight != null) {
    await inflight;
    return;
  }

  Future<void> warmTask() async {
    final imageProvider = _resolveNowPlayingImageProvider(
      ref: ref,
      coverArtId: coverArtId,
      artUrl: artUrl,
    );
    if (imageProvider == null) {
      return;
    }
    await precacheImage(imageProvider, context);
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: imageProvider,
        brightness: brightness,
      );
      _nowPlayingTintColorCache[cacheKey] = scheme.primary;
    } on Exception {
      // Best-effort warm path: ignore extraction failures.
    }
  }

  final future = warmTask();

  _nowPlayingVisualPrewarmInflight[cacheKey] = future;
  try {
    await future;
  } finally {
    final pending = _nowPlayingVisualPrewarmInflight[cacheKey];
    if (identical(pending, future)) {
      final removed = _nowPlayingVisualPrewarmInflight.remove(cacheKey);
      if (removed != null) {
        // The task has already been awaited above.
      }
    }
  }
}

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({
    super.key,
    this.onCollapse,
    this.onShowQueue,
    this.wideEmbeddedMode = false,
    this.compactWideLandscapeMode = false,
    this.onBackInterceptorChanged,
    this.onCompactWideOverlayActiveChanged,
    this.onCompactWideQueueRequestChanged,
  });

  final VoidCallback? onCollapse;
  final VoidCallback? onShowQueue;
  final bool wideEmbeddedMode;
  final bool compactWideLandscapeMode;
  final ValueChanged<bool Function()?>? onBackInterceptorChanged;
  final ValueChanged<bool>? onCompactWideOverlayActiveChanged;
  final ValueChanged<VoidCallback?>? onCompactWideQueueRequestChanged;

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  /// Dominant color extracted from the current cover art for tinting.
  Color? _artTintColor;
  Color? _lastStableTintColor;

  /// The cover art ID that [_artTintColor] was extracted from.
  String? _extractedCoverArtId;

  Future<void> _extractArtColor(String? coverArtId) async {
    final brightness = Theme.of(context).brightness;
    final cacheKey = nowPlayingVisualCacheKeyFor(
      brightness: brightness,
      coverArtId: coverArtId,
      artUrl: null,
    );
    if (cacheKey == _extractedCoverArtId) return;
    _extractedCoverArtId = cacheKey;

    if (cacheKey == null) {
      // Keep the previous tint during transient metadata gaps so the surface
      // does not flash back to default between track transitions.
      return;
    }
    final cachedTint = nowPlayingCachedTintColor(
      brightness: brightness,
      coverArtId: coverArtId,
      artUrl: null,
    );
    if (cachedTint != null) {
      if (mounted) setState(() => _artTintColor = cachedTint);
      return;
    }

    await prewarmNowPlayingVisuals(
      context: context,
      ref: ref,
      brightness: brightness,
      coverArtId: coverArtId,
      artUrl: null,
    );
    final warmedTint = nowPlayingCachedTintColor(
      brightness: brightness,
      coverArtId: coverArtId,
      artUrl: null,
    );
    if (mounted && warmedTint != null) {
      setState(() => _artTintColor = warmedTint);
    }
  }

  Future<void> _extractArtColorFromUrl(String? artUrl) async {
    final brightness = Theme.of(context).brightness;
    final cacheKey = nowPlayingVisualCacheKeyFor(
      brightness: brightness,
      coverArtId: null,
      artUrl: artUrl,
    );
    if (cacheKey == _extractedCoverArtId) return;
    _extractedCoverArtId = cacheKey;

    if (cacheKey == null) {
      // Keep the previous tint during transient metadata gaps so the surface
      // does not flash back to default between track transitions.
      return;
    }
    final cachedTint = nowPlayingCachedTintColor(
      brightness: brightness,
      coverArtId: null,
      artUrl: artUrl,
    );
    if (cachedTint != null) {
      if (mounted) setState(() => _artTintColor = cachedTint);
      return;
    }

    await prewarmNowPlayingVisuals(
      context: context,
      ref: ref,
      brightness: brightness,
      coverArtId: null,
      artUrl: artUrl,
    );
    final warmedTint = nowPlayingCachedTintColor(
      brightness: brightness,
      coverArtId: null,
      artUrl: artUrl,
    );
    if (mounted && warmedTint != null) {
      setState(() => _artTintColor = warmedTint);
    }
  }

  @override
  Widget build(BuildContext context) {
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final effectiveWideMode =
        widget.wideEmbeddedMode || adaptiveContext.useDesktopShell;
    final playback = ref.watch(playerStateProvider);
    final currentSongId = playback.currentSongId;
    final songAsync = currentSongId == null
        ? const AsyncValue<SongsTableData?>.data(null)
        : ref.watch(songByIdProvider(currentSongId));
    final song = songAsync.asData?.value;
    final currentMediaItem = ref.watch(currentMediaItemProvider).asData?.value;
    final artTinted = ref.watch(artTintedNowPlayingProvider);
    final brightness = Theme.of(context).brightness;
    final activeArtUrl = playback.isRadioMode
        ? playback.radioStation?.nowPlayingArtUrl
        : currentMediaItem?.artUri?.toString();
    // ignore: unused_local_variable
    final visualCacheKey = nowPlayingVisualCacheKeyFor(
      brightness: brightness,
      coverArtId: playback.isRadioMode ? null : song?.coverArt,
      artUrl: activeArtUrl,
    );
    final cachedTintColor = artTinted
        ? nowPlayingCachedTintColor(
            brightness: brightness,
            coverArtId: playback.isRadioMode ? null : song?.coverArt,
            artUrl: activeArtUrl,
          )
        : null;

    // Trigger color extraction when art-tinted mode is on.
    if (artTinted) {
      if (!playback.hasActivePlayback) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              (_artTintColor != null || _lastStableTintColor != null)) {
            setState(() {
              _artTintColor = null;
              _lastStableTintColor = null;
            });
          }
        });
      } else if (cachedTintColor == null) {
        // Schedule after build to avoid setState during build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (playback.isRadioMode) {
            final radioArtUrl = playback.radioStation?.nowPlayingArtUrl;
            if (radioArtUrl != null && radioArtUrl.trim().isNotEmpty) {
              _extractArtColorFromUrl(radioArtUrl);
            }
          } else {
            final coverArtId = song?.coverArt;
            if (coverArtId != null && coverArtId.trim().isNotEmpty) {
              _extractArtColor(coverArtId);
            } else {
              final mediaArtUrl = currentMediaItem?.artUri?.toString();
              if (mediaArtUrl != null && mediaArtUrl.trim().isNotEmpty) {
                _extractArtColorFromUrl(mediaArtUrl);
              }
            }
          }
        });
      }
    } else if (!artTinted &&
        (_artTintColor != null || _lastStableTintColor != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            (_artTintColor != null || _lastStableTintColor != null)) {
          setState(() {
            _artTintColor = null;
            _lastStableTintColor = null;
          });
        }
      });
    }

    final surfaceColor = Theme.of(context).colorScheme.surface;
    final extractedTintColor = cachedTintColor ?? _artTintColor;
    if (artTinted &&
        playback.hasActivePlayback &&
        extractedTintColor != null &&
        extractedTintColor != _lastStableTintColor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _lastStableTintColor != extractedTintColor) {
          setState(() => _lastStableTintColor = extractedTintColor);
        }
      });
    }
    final tintColor = artTinted
        ? (extractedTintColor ??
              (playback.hasActivePlayback ? _lastStableTintColor : null))
        : null;
    final mediaQuery = MediaQuery.of(context);
    final flutterView = View.maybeOf(context);
    final rawViewPaddingBottom = flutterView == null
        ? 0.0
        : flutterView.viewPadding.bottom / flutterView.devicePixelRatio;
    final androidBottomInsetFloor =
        Theme.of(context).platform == TargetPlatform.android ? 24.0 : 0.0;
    final inheritedBottomInset = math.max(
      mediaQuery.viewPadding.bottom,
      mediaQuery.padding.bottom,
    );
    final bottomSafeInset = effectiveWideMode
        ? 0.0
        : math.max(androidBottomInsetFloor, inheritedBottomInset);
    final resolvedBottomSafeInset = effectiveWideMode
        ? 0.0
        : math.max(
            bottomSafeInset,
            math.max(
              mediaQuery.systemGestureInsets.bottom,
              rawViewPaddingBottom,
            ),
          );

    final nowPlayingSurface = Material(
      color: surfaceColor,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubic,
        decoration: BoxDecoration(
          gradient: tintColor != null
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    tintColor.withValues(alpha: 0.4),
                    surfaceColor,
                  ],
                  stops: const <double>[0, 0.7],
                )
              : null,
          color: tintColor == null ? surfaceColor : null,
        ),
        // In compact-wide mode the overlay panels must cover the full
        // Material area including any safe-area insets, so we skip the
        // outer SafeArea here.  The body's compactPlayerPage applies the
        // insets itself via MediaQuery.paddingOf so content stays clear of
        // camera cutouts and the status bar.
        child: Builder(
          builder: (context) {
            final nowPlayingBody = _NowPlayingBody(
              playback: playback,
              song: playback.isRadioMode ? null : song,
              wideEmbeddedMode: widget.compactWideLandscapeMode
                  ? true
                  : effectiveWideMode,
              compactWideLandscapeMode: widget.compactWideLandscapeMode,
              onCollapse: widget.onCollapse,
              onBackInterceptorChanged: widget.onBackInterceptorChanged,
              onCompactWideOverlayActiveChanged:
                  widget.onCompactWideOverlayActiveChanged,
              onCompactWideQueueRequestChanged:
                  widget.onCompactWideQueueRequestChanged,
            );

            final surface = widget.compactWideLandscapeMode
                ? nowPlayingBody
                : SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: resolvedBottomSafeInset),
                      child: effectiveWideMode
                          ? Column(
                              children: <Widget>[
                                Expanded(child: nowPlayingBody),
                              ],
                            )
                          : Column(
                              children: <Widget>[
                                const _NowPlayingHandle(),
                                Expanded(child: nowPlayingBody),
                              ],
                            ),
                    ),
                  );

            final platform = Theme.of(context).platform;
            final showCollapseButton =
                widget.onCollapse != null &&
                platform != TargetPlatform.android &&
                platform != TargetPlatform.iOS;

            if (!showCollapseButton) {
              return surface;
            }

            return Stack(
              children: <Widget>[
                Positioned.fill(child: surface),
                Positioned(
                  top: 6,
                  right: 8,
                  child: SafeArea(
                    bottom: false,
                    child: _NowPlayingCollapseButton(
                      onPressed: widget.onCollapse!,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );

    if (widget.onCollapse == null) {
      return nowPlayingSurface;
    }

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (intent) {
              AppLogger.debug(
                '[ACP_INPUT] nowPlaying escape dismissed via local shortcut',
              );
              widget.onCollapse!.call();
              return null;
            },
          ),
        },
        child: nowPlayingSurface,
      ),
    );
  }
}

class _NowPlayingHandle extends StatelessWidget {
  const _NowPlayingHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _NowPlayingCollapseButton extends StatelessWidget {
  const _NowPlayingCollapseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      key: const Key('nowPlayingCloseButton'),
      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
      onPressed: onPressed,
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
    );
  }
}

void _showNowPlayingSettingsSheet(
  BuildContext context,
  WidgetRef ref,
  SongsTableData? song, {
  String? fullscreenLyricsSongId,
  String? fullscreenLyricsTitle,
}) {
  final l10n = AppLocalizations.of(context)!;
  final playbackSpeed =
      ref.read(appSettingsProvider).asData?.value.playbackSpeed ?? 1;

  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    builder: (sheetContext) => Consumer(
      builder: (_, sheetRef, __) {
        final currentSongRating = song == null
            ? null
            : sheetRef.watch(songRatingProvider(song.id)).asData?.value;
        final sheetVolume = sheetRef.watch(playbackVolumeProvider);
        final isRemote = song != null && !isServerAddressableSongId(song.id);
        final songDownloadState = song == null
            ? SongDownloadState.none
            : sheetRef.watch(songDownloadStateProvider(song.id));
        final disabledColor = Theme.of(
          context,
        ).colorScheme.onSurface.withValues(alpha: 0.38);
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        sheetVolume <= 0.01
                            ? Icons.volume_off_rounded
                            : sheetVolume < 0.5
                            ? Icons.volume_down_rounded
                            : Icons.volume_up_rounded,
                        size: 22,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: sheetVolume,
                          min: 0,
                          max: 1,
                          onChanged: (v) {
                            final resolved = sheetRef
                                .read(playbackVolumeProvider.notifier)
                                .setVolume(v);
                            unawaited(
                              sheetRef
                                  .read(audioHandlerProvider)
                                  ?.setVolume(resolved),
                            );
                          },
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '${(sheetVolume * 100).round()}%',
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: Text(l10n.playbackSettingsPlaybackSpeedLabel),
                  subtitle: Text(formatPlaybackSpeed(playbackSpeed)),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _showPlaybackSpeedSheet(context, ref, playbackSpeed);
                  },
                ),
                if (song != null)
                  ListTile(
                    iconColor: isRemote ? disabledColor : null,
                    textColor: isRemote ? disabledColor : null,
                    leading: const Icon(Icons.star_outline),
                    title: Text(l10n.ratingTitle),
                    subtitle: Text(l10n.ratingHint),
                    trailing: isRemote
                        ? IgnorePointer(
                            child: Opacity(
                              opacity: 0.38,
                              child: RatingWidget(
                                rating: currentSongRating,
                                compact: true,
                                onChanged: (_) {},
                              ),
                            ),
                          )
                        : RatingWidget(
                            rating: currentSongRating,
                            compact: true,
                            onChanged: (next) {
                              unawaited(
                                setSongRating(
                                  song.id,
                                  next,
                                  sheetRef,
                                ).catchError((_) {
                                  if (context.mounted) {
                                    AppNoticeMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(l10n.ratingUpdateFailed),
                                      ),
                                    );
                                  }
                                }),
                              );
                            },
                          ),
                    onTap: isRemote
                        ? () => AppNoticeMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.remoteSourceActionUnavailable),
                            ),
                          )
                        : null,
                  ),
                if (fullscreenLyricsSongId != null &&
                    fullscreenLyricsTitle != null)
                  ListTile(
                    leading: const Icon(Icons.fullscreen),
                    title: Text(l10n.nowPlayingLyrics),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _openFullscreenLyricsRoute(
                        context,
                        fullscreenLyricsSongId,
                        fullscreenLyricsTitle,
                      );
                    },
                  ),
                if (song?.albumId != null && song!.albumId!.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.album_outlined),
                    title: Text(l10n.nowPlayingGoToAlbum),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      NavService.goToAlbum(context, ref, song.albumId!);
                    },
                  ),
                if (song?.artistId != null && song!.artistId!.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(l10n.nowPlayingGoToArtist),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      NavService.goToArtist(context, ref, song.artistId!);
                    },
                  ),
                if (song != null)
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: Text(l10n.librarySongMenuAddToPlaylist),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      showAddToPlaylistSheet(context, ref, [song.id]);
                    },
                  ),
                if (song != null &&
                    songDownloadState.status == SongDownloadStatus.downloaded)
                  ListTile(
                    leading: Icon(
                      Icons.delete_outlined,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    title: Text(
                      l10n.deleteDownloadAction,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(
                        confirmAndDeleteDownload(
                          context,
                          sheetRef,
                          song.id,
                        ),
                      );
                    },
                  )
                else if (song != null &&
                    songDownloadState.status != SongDownloadStatus.queued &&
                    songDownloadState.status != SongDownloadStatus.downloading)
                  ListTile(
                    iconColor: isRemote ? disabledColor : null,
                    textColor: isRemote ? disabledColor : null,
                    leading: const Icon(Icons.download_outlined),
                    title: Text(l10n.downloadAction),
                    onTap: () async {
                      if (isRemote) {
                        AppNoticeMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(l10n.remoteSourceActionUnavailable),
                          ),
                        );
                        return;
                      }
                      Navigator.of(sheetContext).pop();
                      final choice = await showDownloadQualitySheet(context);
                      if (choice == null || !context.mounted) return;
                      final service = ref.read(downloadServiceProvider);
                      await service.enqueueSong(
                        song.id,
                        quality: choice.quality,
                        format: choice.format,
                      );
                      if (context.mounted) {
                        AppNoticeMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l10n.downloadSongQueued)),
                        );
                      }
                    },
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<void> _openFullscreenLyricsRoute(
  BuildContext context,
  String songId,
  String title,
) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => _FullscreenLyricsPage(songId: songId, title: title),
    ),
  );
}

void _showPlaybackSpeedSheet(
  BuildContext context,
  WidgetRef ref,
  double initialSpeed,
) {
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (context) => _PlaybackSpeedSheet(initialSpeed: initialSpeed),
  );
}

class _NowPlayingBody extends ConsumerStatefulWidget {
  const _NowPlayingBody({
    required this.playback,
    this.song,
    this.wideEmbeddedMode = false,
    this.compactWideLandscapeMode = false,
    this.onCollapse,
    this.onBackInterceptorChanged,
    this.onCompactWideOverlayActiveChanged,
    this.onCompactWideQueueRequestChanged,
  });

  final PlaybackSnapshot playback;
  final SongsTableData? song;
  final bool wideEmbeddedMode;
  final bool compactWideLandscapeMode;
  final VoidCallback? onCollapse;
  final ValueChanged<bool Function()?>? onBackInterceptorChanged;
  final ValueChanged<bool>? onCompactWideOverlayActiveChanged;
  final ValueChanged<VoidCallback?>? onCompactWideQueueRequestChanged;

  @override
  ConsumerState<_NowPlayingBody> createState() => _NowPlayingBodyState();
}

class _NowPlayingBodyState extends ConsumerState<_NowPlayingBody>
    with SingleTickerProviderStateMixin {
  _WideNowPlayingPanel _widePanel = _WideNowPlayingPanel.none;
  bool _showLyrics = false;
  bool _showWideFullscreenLyrics = false;
  bool? _lastReportedCompactWideOverlayActive;
  String? _lastPrefetchedNextSongId;
  final ScrollController _embeddedQueueScrollController = ScrollController();
  static const double _wideSwipeDismissDistance = 72;
  static const double _wideSwipeQueueDistance = 96;
  double _wideSwipeDistance = 0;
  bool _handledWideSwipe = false;
  ManualTrackChangeDirection? _pendingManualSkipDirection;
  String? _manualSkipFromSongId;
  int _lastHandledManualSkipCueToken = 0;
  bool _manualSkipConsumeScheduled = false;
  Timer? _manualSkipCueResetTimer;
  Timer? _manualSkipConsumeTimer;
  String? _lastArtTransitionSongId;
  int? _lastArtTransitionQueueIndex;
  int _lastArtTransitionQueueLength = 0;
  ManualTrackChangeDirection _latchedArtTransitionDirection =
      ManualTrackChangeDirection.next;
  late final AnimatedSwitcherTransitionBuilder _songSwapArtTransitionBuilder;
  late final AnimationController _artSwipeController;
  bool _artSwipeAwaitingTrackChange = false;
  bool _artSwipeSettling = false;
  String? _artSwipeFromSongId;
  Timer? _artSwipeResetTimer;
  bool _artSwipeReleaseHandoffScheduled = false;

  bool _dismissInternalOverlaysIfVisible() {
    if (_widePanel != _WideNowPlayingPanel.none) {
      _updateWideOverlayState(() {
        _widePanel = _WideNowPlayingPanel.none;
      });
      return true;
    }
    if (_showWideFullscreenLyrics) {
      _updateWideOverlayState(() {
        _showWideFullscreenLyrics = false;
      });
      return true;
    }
    return false;
  }

  void _publishBackInterceptor() {
    widget.onBackInterceptorChanged?.call(_dismissInternalOverlaysIfVisible);
  }

  bool get _compactWideOverlayActive {
    return widget.compactWideLandscapeMode &&
        (_widePanel != _WideNowPlayingPanel.none || _showWideFullscreenLyrics);
  }

  void _publishCompactWideOverlayActiveState({bool defer = false}) {
    final active = _compactWideOverlayActive;
    if (_lastReportedCompactWideOverlayActive == active) {
      return;
    }
    _lastReportedCompactWideOverlayActive = active;
    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        widget.onCompactWideOverlayActiveChanged?.call(active);
      });
      return;
    }
    widget.onCompactWideOverlayActiveChanged?.call(active);
  }

  void _publishCompactWideQueueRequest() {
    widget.onCompactWideQueueRequestChanged?.call(
      widget.compactWideLandscapeMode ? _showQueuePanel : null,
    );
  }

  void _updateWideOverlayState(VoidCallback update) {
    setState(update);
    _publishCompactWideOverlayActiveState();
  }

  @override
  void initState() {
    super.initState();
    _songSwapArtTransitionBuilder = (child, animation) =>
        _songSwapArtDirectionalTransitionBuilder(
          child,
          animation,
          direction: _latchedArtTransitionDirection,
        );
    _artSwipeController = AnimationController(
      vsync: this,
      lowerBound: -1,
      upperBound: 1,
      value: 0,
      duration: const Duration(milliseconds: 220),
    );
    _publishBackInterceptor();
    _publishCompactWideOverlayActiveState(defer: true);
    _publishCompactWideQueueRequest();
  }

  @override
  void didUpdateWidget(covariant _NowPlayingBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onBackInterceptorChanged != widget.onBackInterceptorChanged) {
      _publishBackInterceptor();
    }
    if (oldWidget.compactWideLandscapeMode != widget.compactWideLandscapeMode ||
        oldWidget.onCompactWideOverlayActiveChanged !=
            widget.onCompactWideOverlayActiveChanged) {
      _publishCompactWideOverlayActiveState(defer: true);
    }
    if (oldWidget.compactWideLandscapeMode != widget.compactWideLandscapeMode ||
        oldWidget.onCompactWideQueueRequestChanged !=
            widget.onCompactWideQueueRequestChanged) {
      _publishCompactWideQueueRequest();
    }
    if (_artSwipeAwaitingTrackChange) {
      final fromSongId = _artSwipeFromSongId;
      final currentSongId = widget.playback.currentSongId;
      if (fromSongId == null ||
          currentSongId == null ||
          currentSongId != fromSongId) {
        _artSwipeResetTimer?.cancel();
        _artSwipeResetTimer = null;
        _artSwipeFromSongId = null;
        _artSwipeAwaitingTrackChange = false;
        _artSwipeSettling = true;
        _artSwipeController.value = 0;
        _scheduleArtSwipeHandoffRelease();
      }
    }
  }

  @override
  void dispose() {
    _manualSkipCueResetTimer?.cancel();
    _manualSkipConsumeTimer?.cancel();
    _artSwipeResetTimer?.cancel();
    _artSwipeController.dispose();
    widget.onBackInterceptorChanged?.call(null);
    widget.onCompactWideOverlayActiveChanged?.call(false);
    widget.onCompactWideQueueRequestChanged?.call(null);
    _embeddedQueueScrollController.dispose();
    super.dispose();
  }

  void _armManualSkipCue(ManualTrackChangeCue cue) {
    if (cue.token <= _lastHandledManualSkipCueToken) {
      return;
    }
    _lastHandledManualSkipCueToken = cue.token;
    _manualSkipCueResetTimer?.cancel();
    _manualSkipConsumeTimer?.cancel();
    final fromSongId =
        cue.fromSongId ?? ref.read(playerStateProvider).currentSongId;
    if (fromSongId == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _pendingManualSkipDirection = cue.direction;
      _manualSkipFromSongId = fromSongId;
      _manualSkipConsumeScheduled = false;
    });
    _manualSkipCueResetTimer = Timer(_manualSkipCueTimeout(), () {
      if (!mounted) {
        return;
      }
      setState(_clearManualSkipCue);
    });
  }

  Duration _manualSkipCueTimeout() {
    final settings = ref.read(appSettingsProvider).asData?.value;
    final crossfadeSeconds = settings?.crossfadeDurationSeconds ?? 5;
    // Budget for decode/prewarm + fade + swap jitter before we consider
    // the manual cue stale.
    final timeoutSeconds = (crossfadeSeconds + 10).clamp(10, 30);
    return Duration(seconds: timeoutSeconds);
  }

  void _clearManualSkipCue() {
    _pendingManualSkipDirection = null;
    _manualSkipFromSongId = null;
    _manualSkipConsumeScheduled = false;
    _manualSkipCueResetTimer?.cancel();
    _manualSkipCueResetTimer = null;
    _manualSkipConsumeTimer?.cancel();
    _manualSkipConsumeTimer = null;
  }

  ManualTrackChangeDirection? _resolveManualSkipDirectionForTransition(
    PlaybackSnapshot playback,
  ) {
    final pendingDirection = _pendingManualSkipDirection;
    final fromSongId = _manualSkipFromSongId;
    final currentSongId = playback.currentSongId;
    if (pendingDirection == null ||
        fromSongId == null ||
        currentSongId == null ||
        currentSongId == fromSongId) {
      return null;
    }
    if (!_manualSkipConsumeScheduled) {
      _manualSkipConsumeScheduled = true;
      // Keep the manual direction alive for the full swap animation; clearing
      // on the next frame can cause AnimatedSwitcher to rebuild with the
      // default transition mid-flight.
      _manualSkipConsumeTimer = Timer(const Duration(milliseconds: 480), () {
        if (!mounted) {
          return;
        }
        setState(_clearManualSkipCue);
      });
    }
    return pendingDirection;
  }

  ManualTrackChangeDirection? _inferTrackChangeDirectionFromQueue(
    PlaybackSnapshot playback,
  ) {
    final previousSongId = _lastArtTransitionSongId;
    final previousIndex = _lastArtTransitionQueueIndex;
    final previousLength = _lastArtTransitionQueueLength;
    final currentSongId = playback.currentSongId;
    final currentIndex = playback.currentIndex;
    final currentLength = playback.queueSongIds.length;

    ManualTrackChangeDirection? inferredDirection;
    final songChanged =
        previousSongId != null &&
        currentSongId != null &&
        previousSongId != currentSongId;
    if (songChanged &&
        previousIndex != null &&
        currentIndex != null &&
        previousLength > 0 &&
        currentLength > 0) {
      if (currentIndex > previousIndex) {
        inferredDirection = ManualTrackChangeDirection.next;
      } else if (currentIndex < previousIndex) {
        inferredDirection = ManualTrackChangeDirection.previous;
      } else if (previousLength == currentLength) {
        if (previousIndex == previousLength - 1 && currentIndex == 0) {
          inferredDirection = ManualTrackChangeDirection.next;
        } else if (previousIndex == 0 && currentIndex == previousLength - 1) {
          inferredDirection = ManualTrackChangeDirection.previous;
        }
      }
    }

    _lastArtTransitionSongId = currentSongId;
    _lastArtTransitionQueueIndex = currentIndex;
    _lastArtTransitionQueueLength = currentLength;
    return inferredDirection;
  }

  ManualTrackChangeDirection? _resolveArtTransitionDirection(
    PlaybackSnapshot playback,
  ) {
    final manualDirection = _resolveManualSkipDirectionForTransition(playback);
    final inferredDirection = _inferTrackChangeDirectionFromQueue(playback);
    return manualDirection ?? inferredDirection;
  }

  void _updateLatchedArtTransitionDirection(PlaybackSnapshot playback) {
    final direction = _resolveArtTransitionDirection(playback);
    if (direction != null) {
      _latchedArtTransitionDirection = direction;
    }
  }

  _NowPlayingLayoutMode _resolveLayoutMode(double width) {
    if (width >= 920) {
      return _NowPlayingLayoutMode.split;
    }
    if (width >= 760) {
      return _NowPlayingLayoutMode.standard;
    }
    return _NowPlayingLayoutMode.compact;
  }

  _NowPlayingSplitMetrics? _resolveSplitMetrics(BoxConstraints constraints) {
    final sidePadding = widget.wideEmbeddedMode ? 14.0 : 16.0;
    final contentWidth = constraints.maxWidth - (sidePadding * 2);
    final contentHeight = constraints.maxHeight;
    // Allow the split layout down to focus-player-mode window sizes
    // (min focus window: 840 × 376).
    if (contentWidth < 790 || contentHeight < 360) {
      return null;
    }

    final gap = (contentWidth * 0.014).clamp(14.0, 20.0);
    final paneInnerPadding = 18.0;
    final usableArtHeight =
        contentHeight - (widget.wideEmbeddedMode ? 40.0 : 52.0);

    var leftPaneWidth = (contentWidth * (widget.wideEmbeddedMode ? 0.54 : 0.56))
        .clamp(400.0, contentWidth * 0.66);
    var rightPaneWidth = contentWidth - leftPaneWidth - gap;

    if (rightPaneWidth < 360) {
      rightPaneWidth = 360;
      leftPaneWidth = contentWidth - rightPaneWidth - gap;
    }
    if (rightPaneWidth > 560) {
      rightPaneWidth = 560;
      leftPaneWidth = contentWidth - rightPaneWidth - gap;
    }
    if (leftPaneWidth < 360 || rightPaneWidth < 320) {
      return null;
    }

    final artWidthBound = leftPaneWidth - (paneInnerPadding * 2);
    final artSize = math
        .min(artWidthBound, usableArtHeight)
        .clamp(260.0, 760.0);

    return _NowPlayingSplitMetrics(
      outerPadding: sidePadding,
      gap: gap,
      leftPaneWidth: leftPaneWidth,
      rightPaneWidth: rightPaneWidth,
      artSize: artSize,
    );
  }

  String? _resolveNextSongIdForPrefetch(PlaybackSnapshot playback) {
    if (playback.isRadioMode) {
      return null;
    }
    final ids = playback.queueSongIds;
    final currentIndex = playback.currentIndex;
    if (ids.isEmpty ||
        currentIndex == null ||
        currentIndex < 0 ||
        currentIndex >= ids.length) {
      return null;
    }
    var nextIndex = currentIndex + 1;
    if (nextIndex >= ids.length) {
      if (playback.repeatMode != AudioServiceRepeatMode.all) {
        return null;
      }
      nextIndex = 0;
    }
    return ids[nextIndex];
  }

  String? _resolvePreviousSongIdForSwipe(PlaybackSnapshot playback) {
    if (playback.isRadioMode) {
      return null;
    }
    final ids = playback.queueSongIds;
    final currentIndex = playback.currentIndex;
    if (ids.isEmpty ||
        currentIndex == null ||
        currentIndex < 0 ||
        currentIndex >= ids.length) {
      return null;
    }
    var previousIndex = currentIndex - 1;
    if (previousIndex < 0) {
      if (playback.repeatMode != AudioServiceRepeatMode.all) {
        return null;
      }
      previousIndex = ids.length - 1;
    }
    return ids[previousIndex];
  }

  bool _canManualSkipDirection(
    PlaybackSnapshot playback,
    ManualTrackChangeDirection direction,
  ) {
    if (playback.isRadioMode) {
      return false;
    }
    return switch (direction) {
      ManualTrackChangeDirection.next =>
        _resolveNextSongIdForPrefetch(playback) != null,
      ManualTrackChangeDirection.previous =>
        _resolvePreviousSongIdForSwipe(playback) != null,
    };
  }

  void _scheduleNextSongCoverArtPrefetch({
    required String? nextSongId,
    required String? coverArtId,
  }) {
    if (nextSongId == null || nextSongId == _lastPrefetchedNextSongId) {
      return;
    }
    _lastPrefetchedNextSongId = nextSongId;
    final trimmedCoverArt = coverArtId?.trim() ?? '';
    if (trimmedCoverArt.isEmpty) {
      return;
    }
    final api = ref.read(subsonicApiProvider);
    if (api == null) {
      return;
    }
    final artUrl = api
        .getCoverArtUrl(id: trimmedCoverArt, size: 768)
        .toString();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _lastPrefetchedNextSongId != nextSongId) {
        return;
      }
      final cacheManager = ref.read(coverArtCacheManagerProvider).asData?.value;
      final ImageProvider<Object> imageProvider = cacheManager == null
          ? NetworkImage(artUrl)
          : CachedNetworkImageProvider(artUrl, cacheManager: cacheManager);
      unawaited(precacheImage(imageProvider, context));
    });
  }

  void _togglePlayPause() {
    final handler = ref.read(audioHandlerProvider);
    if (handler == null) return;
    if (widget.playback.playing) {
      unawaited(handler.pause());
    } else {
      unawaited(handler.play());
    }
  }

  void _handleArtHorizontalDragStart(DragStartDetails details) {
    if (_artSwipeAwaitingTrackChange) {
      return;
    }
    _artSwipeResetTimer?.cancel();
    _artSwipeResetTimer = null;
    _artSwipeController.stop();
  }

  void _handleArtHorizontalDragUpdate(
    DragUpdateDetails details,
    double viewportWidth,
  ) {
    if (_artSwipeAwaitingTrackChange) {
      return;
    }
    final delta = details.primaryDelta;
    if (delta == null) {
      return;
    }
    final safeWidth = viewportWidth <= 0 ? 1.0 : viewportWidth;
    final normalizedDelta = delta / safeWidth;
    var nextValue = _artSwipeController.value + normalizedDelta;
    final swipingTowardNext = nextValue < 0;
    final blockedDirection = swipingTowardNext
        ? !_canManualSkipDirection(
            widget.playback,
            ManualTrackChangeDirection.next,
          )
        : !_canManualSkipDirection(
            widget.playback,
            ManualTrackChangeDirection.previous,
          );
    if (blockedDirection) {
      // Edge resistance to avoid hard snapping when no track exists in
      // the swiped direction.
      nextValue = _artSwipeController.value + (normalizedDelta * 0.28);
      nextValue = nextValue.clamp(-0.2, 0.2);
    } else {
      nextValue = nextValue.clamp(-1.0, 1.0);
    }
    _artSwipeController.value = nextValue;
  }

  Future<void> _animateArtSwipeTo(
    double target, {
    Duration duration = const Duration(milliseconds: 180),
    Curve curve = Curves.easeOutCubic,
  }) {
    _artSwipeController.duration = duration;
    return _artSwipeController.animateTo(target, curve: curve);
  }

  void _scheduleArtSwipeHandoffRelease() {
    if (_artSwipeReleaseHandoffScheduled) {
      return;
    }
    _artSwipeReleaseHandoffScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _artSwipeReleaseHandoffScheduled = false;
      if (!mounted || !_artSwipeSettling) {
        return;
      }
      setState(() {
        _artSwipeSettling = false;
      });
    });
  }

  Future<void> _animateEdgeSnapback(
    ManualTrackChangeDirection direction,
  ) async {
    final edgeTarget = switch (direction) {
      ManualTrackChangeDirection.next => -0.14,
      ManualTrackChangeDirection.previous => 0.14,
    };
    await _animateArtSwipeTo(
      edgeTarget,
      duration: const Duration(milliseconds: 95),
      curve: Curves.easeOut,
    );
    await _animateArtSwipeTo(
      0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _triggerManualSkipWithAnimation(
    ManualTrackChangeDirection direction, {
    double? initialSwipe,
  }) async {
    if (_artSwipeAwaitingTrackChange || _artSwipeSettling) {
      return;
    }
    if (!_canManualSkipDirection(widget.playback, direction)) {
      await _animateEdgeSnapback(direction);
      return;
    }

    if (initialSwipe != null) {
      _artSwipeController.value = initialSwipe.clamp(-1.0, 1.0);
    }
    final target = switch (direction) {
      ManualTrackChangeDirection.next => -1.0,
      ManualTrackChangeDirection.previous => 1.0,
    };
    final remainingDistance = (target - _artSwipeController.value).abs();
    final commitMs = (190 + (remainingDistance * 170)).round().clamp(190, 320);
    await _animateArtSwipeTo(
      target,
      duration: Duration(milliseconds: commitMs),
      curve: Curves.easeOutCubic,
    );

    final handler = ref.read(audioHandlerProvider);
    if (handler == null) {
      await _animateArtSwipeTo(0, duration: const Duration(milliseconds: 180));
      return;
    }

    setState(() {
      _latchedArtTransitionDirection = direction;
      _artSwipeAwaitingTrackChange = true;
      _artSwipeSettling = false;
      _artSwipeFromSongId = widget.playback.currentSongId;
    });
    _artSwipeResetTimer?.cancel();
    _artSwipeResetTimer = Timer(
      const Duration(milliseconds: 1800),
      _resetArtSwipeAfterCommitTimeout,
    );
    unawaited(HapticFeedback.selectionClick());
    switch (direction) {
      case ManualTrackChangeDirection.next:
        unawaited(handler.skipToNext());
      case ManualTrackChangeDirection.previous:
        unawaited(handler.skipToPrevious());
    }
  }

  void _resetArtSwipeAfterCommitTimeout() {
    if (!mounted || !_artSwipeAwaitingTrackChange) {
      return;
    }
    _artSwipeResetTimer = null;
    setState(() {
      _artSwipeAwaitingTrackChange = false;
      _artSwipeFromSongId = null;
      _artSwipeSettling = false;
    });
    _artSwipeController.value = 0;
  }

  Future<void> _handleArtHorizontalDragEnd(DragEndDetails details) async {
    if (_artSwipeAwaitingTrackChange || _artSwipeSettling) {
      return;
    }
    final swipe = _artSwipeController.value;
    final velocity = details.primaryVelocity ?? 0;
    final shouldCommit = swipe.abs() > 0.24 || velocity.abs() > 980;
    if (!shouldCommit) {
      await _animateArtSwipeTo(0, duration: const Duration(milliseconds: 220));
      return;
    }

    final direction = (swipe < -0.02 || (swipe.abs() <= 0.02 && velocity < 0))
        ? ManualTrackChangeDirection.next
        : ManualTrackChangeDirection.previous;
    await _triggerManualSkipWithAnimation(direction, initialSwipe: swipe);
  }

  void _handleArtHorizontalDragCancel() {
    if (_artSwipeAwaitingTrackChange || _artSwipeSettling) {
      return;
    }
    unawaited(
      _animateArtSwipeTo(0, duration: const Duration(milliseconds: 220)),
    );
  }

  void _handleManualPreviousButton() {
    unawaited(
      _triggerManualSkipWithAnimation(ManualTrackChangeDirection.previous),
    );
  }

  void _handleManualNextButton() {
    unawaited(_triggerManualSkipWithAnimation(ManualTrackChangeDirection.next));
  }

  Widget _buildInteractiveSwipeableArt({
    required Key key,
    required Widget currentArt,
    required Widget? previousArt,
    required Widget? nextArt,
    required bool swipeEnabled,
  }) {
    final enabled =
        swipeEnabled && !_artSwipeAwaitingTrackChange && !_artSwipeSettling;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: _togglePlayPause,
          onHorizontalDragStart: enabled ? _handleArtHorizontalDragStart : null,
          onHorizontalDragUpdate: enabled
              ? (details) => _handleArtHorizontalDragUpdate(details, width)
              : null,
          onHorizontalDragEnd: enabled ? _handleArtHorizontalDragEnd : null,
          onHorizontalDragCancel: enabled
              ? _handleArtHorizontalDragCancel
              : null,
          child: AnimatedBuilder(
            animation: _artSwipeController,
            builder: (context, _) {
              final swipe = _artSwipeController.value.clamp(-1.0, 1.0);
              final absSwipe = swipe.abs();
              final incoming = swipe < -0.001
                  ? nextArt
                  : (swipe > 0.001 ? previousArt : null);
              final incomingOffsetX = swipe < 0 ? 1 + swipe : -1 + swipe;
              return ClipRect(
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.hardEdge,
                  children: <Widget>[
                    if (incoming != null)
                      FractionalTranslation(
                        translation: Offset(incomingOffsetX, 0),
                        child: Transform.scale(
                          scale: 0.84 + (0.16 * absSwipe),
                          child: incoming,
                        ),
                      ),
                    FractionalTranslation(
                      translation: Offset(swipe, 0),
                      child: Transform.scale(
                        scale: 1 - (0.18 * absSwipe),
                        child: currentArt,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _handleWideVerticalSwipe(
    DragEndDetails details, {
    required bool splitLayout,
  }) {
    if (!widget.wideEmbeddedMode) {
      return;
    }
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -320 && splitLayout) {
      _showQueuePanel();
      return;
    }
    if (velocity > 320) {
      _dismissWideOverlayOrNowPlaying();
    }
  }

  void _showQueuePanel() {
    _updateWideOverlayState(() {
      _showWideFullscreenLyrics = false;
      _widePanel = _WideNowPlayingPanel.queue;
    });
  }

  void _dismissWideOverlayOrNowPlaying() {
    if (_widePanel != _WideNowPlayingPanel.none) {
      _updateWideOverlayState(() {
        _widePanel = _WideNowPlayingPanel.none;
      });
      return;
    }
    if (_showWideFullscreenLyrics) {
      _updateWideOverlayState(() {
        _showWideFullscreenLyrics = false;
      });
      return;
    }
    widget.onCollapse?.call();
  }

  void _handleWideVerticalDragStart(DragStartDetails details) {
    _wideSwipeDistance = 0;
    _handledWideSwipe = false;
  }

  void _handleWideVerticalDragUpdate(
    DragUpdateDetails details, {
    required bool splitLayout,
  }) {
    if (!widget.wideEmbeddedMode || _handledWideSwipe) {
      return;
    }
    final delta = details.primaryDelta;
    if (delta == null) {
      return;
    }
    _wideSwipeDistance += delta;

    if (_wideSwipeDistance >= _wideSwipeDismissDistance) {
      _handledWideSwipe = true;
      _dismissWideOverlayOrNowPlaying();
      return;
    }

    if (splitLayout && _wideSwipeDistance <= -_wideSwipeQueueDistance) {
      _handledWideSwipe = true;
      _showQueuePanel();
    }
  }

  void _handleWideVerticalDragEnd(
    DragEndDetails details, {
    required bool splitLayout,
  }) {
    if (!_handledWideSwipe) {
      _handleWideVerticalSwipe(details, splitLayout: splitLayout);
    }
    _wideSwipeDistance = 0;
    _handledWideSwipe = false;
  }

  void _handleWideVerticalDragCancel() {
    _wideSwipeDistance = 0;
    _handledWideSwipe = false;
  }

  Future<void> _openLyricsFullscreen(
    BuildContext context,
    String songId,
    String title,
  ) async {
    if (widget.wideEmbeddedMode &&
        (_widePanel != _WideNowPlayingPanel.none ||
            _showWideFullscreenLyrics)) {
      _updateWideOverlayState(() {
        _widePanel = _WideNowPlayingPanel.none;
        _showWideFullscreenLyrics = false;
      });
    }
    await _openFullscreenLyricsRoute(context, songId, title);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final song = widget.song;
    final playback = widget.playback;
    final isRadio = playback.isRadioMode;
    final radioMeta = playback.radioStation;
    final albumDetails =
        !isRadio && song?.albumId != null && song!.albumId!.isNotEmpty
        ? ref.watch(albumProvider(song.albumId!)).asData?.value?.album
        : null;
    final currentMediaItem = ref.watch(currentMediaItemProvider).asData?.value;
    final playbackSpeed =
        ref.watch(appSettingsProvider).asData?.value.playbackSpeed ?? 1;
    final fullscreenLyricsMode = ref.watch(fullscreenModeLyricsProvider);
    ref.listen<AsyncValue<ManualTrackChangeCue>>(manualTrackChangeCueProvider, (
      _,
      next,
    ) {
      final cue = next.asData?.value;
      if (cue != null) {
        _armManualSkipCue(cue);
      }
    });
    _updateLatchedArtTransitionDirection(playback);
    final songSwapTransitionBuilder = _songSwapTransitionBuilder;
    const songSwapArtDuration = Duration(milliseconds: 250);
    final artHandoffActive = _artSwipeAwaitingTrackChange || _artSwipeSettling;
    final effectiveSongSwapArtDuration = artHandoffActive
        ? Duration.zero
        : songSwapArtDuration;
    final effectiveSongSwapArtTransitionBuilder = artHandoffActive
        ? _identityTransitionBuilder
        : _songSwapArtTransitionBuilder;

    final title = isRadio
        ? (radioMeta?.nowPlayingTitle ??
              radioMeta?.stationName ??
              l10n.radioTitle)
        : (song?.title ??
              currentMediaItem?.title ??
              l10n.nowPlayingUnknownTrack);
    final artist = isRadio
        ? (radioMeta?.nowPlayingArtist ?? radioMeta?.stationName ?? '')
        : (song?.artistName ??
              currentMediaItem?.artist ??
              l10n.nowPlayingUnknownArtist);
    final mediaItemArtistIdRaw = currentMediaItem?.extras?['artistId'];
    final mediaItemArtistId = mediaItemArtistIdRaw is String
        ? mediaItemArtistIdRaw.trim()
        : '';
    final resolvedArtistId =
        (song?.artistId != null && song!.artistId!.trim().isNotEmpty)
        ? song.artistId!.trim()
        : (mediaItemArtistId.isNotEmpty ? mediaItemArtistId : null);
    final album = isRadio
        ? l10n.radioLive
        : (song?.albumName ??
              currentMediaItem?.album ??
              l10n.nowPlayingUnknownAlbum);
    final coverArtId = song?.coverArt;
    final mediaArtUrl = currentMediaItem?.artUri?.toString();
    final hasCoverArtId = coverArtId != null && coverArtId.trim().isNotEmpty;
    final hasMediaArtUrl = mediaArtUrl != null && mediaArtUrl.trim().isNotEmpty;
    final nowPlayingVisualKey = isRadio
        ? 'radio:${radioMeta?.nowPlayingTitle ?? ''}:${radioMeta?.nowPlayingArtist ?? ''}:${radioMeta?.nowPlayingArtUrl ?? ''}'
        : 'song:${playback.currentSongId ?? currentMediaItem?.id ?? 'none'}';
    final artVisualKey =
        '$nowPlayingVisualKey:${coverArtId ?? mediaArtUrl ?? 'no-art'}';
    final nextSongId = _resolveNextSongIdForPrefetch(playback);
    final nextSong = nextSongId == null
        ? null
        : ref.watch(songByIdProvider(nextSongId)).asData?.value;
    final previousSongId = _resolvePreviousSongIdForSwipe(playback);
    final previousSong = previousSongId == null
        ? null
        : ref.watch(songByIdProvider(previousSongId)).asData?.value;
    if (nextSong != null &&
        nextSong.albumId != null &&
        nextSong.albumId!.isNotEmpty) {
      ref.watch(albumProvider(nextSong.albumId!));
    }
    _scheduleNextSongCoverArtPrefetch(
      nextSongId: nextSongId,
      coverArtId: nextSong?.coverArt,
    );

    // Clear any open overlay panel when the player collapses in compact-wide
    // mode so it does not reappear the next time the user expands the player.
    ref.listen<bool>(playerSheetExpandedProvider, (_, nowExpanded) {
      if (widget.compactWideLandscapeMode && !nowExpanded) {
        if (_widePanel != _WideNowPlayingPanel.none ||
            _showWideFullscreenLyrics) {
          _updateWideOverlayState(() {
            _widePanel = _WideNowPlayingPanel.none;
            _showWideFullscreenLyrics = false;
          });
        }
      }
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutMode = _resolveLayoutMode(constraints.maxWidth);
        final splitMetrics = layoutMode == _NowPlayingLayoutMode.split
            ? _resolveSplitMetrics(constraints)
            : null;
        final isSplitNowPlaying = splitMetrics != null;
        final supportsSplitPanelOverlay =
            widget.wideEmbeddedMode && isSplitNowPlaying;
        final openFullscreenLyricsFromSettings = playback.currentSongId == null
            ? null
            : () {
                _updateWideOverlayState(() {
                  _showWideFullscreenLyrics = false;
                  _widePanel = _WideNowPlayingPanel.none;
                });
                unawaited(
                  _openLyricsFullscreen(
                    context,
                    playback.currentSongId!,
                    title,
                  ),
                );
              };

        if (widget.compactWideLandscapeMode) {
          // Include MediaQuery safe-area insets so the player content
          // stays clear of camera cut-outs.  The outer SafeArea is skipped
          // in compact-wide mode so the overlay panels can be truly
          // full-screen, making this the only place the insets are applied.
          final mediaPadding = MediaQuery.paddingOf(context);
          // Left padding is deliberately larger to give the album art some
          // breathing room from the navigation rail.
          final compactPadding = EdgeInsets.fromLTRB(
            20 + mediaPadding.left,
            (constraints.maxHeight < 520 ? 8 : 12) + mediaPadding.top,
            12 + mediaPadding.right,
            10 + mediaPadding.bottom,
          );
          final gap = 10.0;
          final artPaneWidth = (constraints.maxWidth * 0.44).clamp(
            220.0,
            440.0,
          );
          final artMaxSize = math
              .min(artPaneWidth - 12, constraints.maxHeight * 0.68)
              .clamp(180.0, 380.0);
          final showInlineLyrics =
              _showLyrics &&
              !_showWideFullscreenLyrics &&
              playback.currentSongId != null;

          if (_showWideFullscreenLyrics && playback.currentSongId == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _updateWideOverlayState(() {
                  _showWideFullscreenLyrics = false;
                });
              }
            });
          }

          final compactWideArtSwitcher = AnimatedSwitcher(
            duration: effectiveSongSwapArtDuration,
            switchInCurve: Curves.linear,
            switchOutCurve: Curves.linear,
            layoutBuilder: _coverArtSwitcherLayoutBuilder,
            transitionBuilder: effectiveSongSwapArtTransitionBuilder,
            child: _buildInteractiveSwipeableArt(
              key: ValueKey<String>('compact-wide-cover-$artVisualKey'),
              swipeEnabled: !isRadio,
              currentArt: hasCoverArtId
                  ? _CoverArt(
                      coverArtId: coverArtId,
                      semanticLabel: title,
                      maxSize: artMaxSize,
                    )
                  : (hasMediaArtUrl
                        ? _RadioCoverArt(
                            artUrl: mediaArtUrl,
                            maxSize: artMaxSize,
                          )
                        : _CoverArt(
                            coverArtId: null,
                            semanticLabel: title,
                            maxSize: artMaxSize,
                          )),
              previousArt: previousSong == null
                  ? null
                  : _CoverArt(
                      coverArtId: previousSong.coverArt,
                      semanticLabel: previousSong.title.isNotEmpty
                          ? previousSong.title
                          : l10n.nowPlayingUnknownTrack,
                      maxSize: artMaxSize,
                    ),
              nextArt: nextSong == null
                  ? null
                  : _CoverArt(
                      coverArtId: nextSong.coverArt,
                      semanticLabel: nextSong.title.isNotEmpty
                          ? nextSong.title
                          : l10n.nowPlayingUnknownTrack,
                      maxSize: artMaxSize,
                    ),
            ),
          );

          final coverOrLyrics = isRadio
              ? _RadioCoverArt(
                  artUrl: radioMeta?.nowPlayingArtUrl,
                  maxSize: artMaxSize,
                )
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: _coverArtSwitcherLayoutBuilder,
                  transitionBuilder: _songSwapTransitionBuilder,
                  child: showInlineLyrics
                      ? _InlineLyrics(
                          key: ValueKey<String>(
                            'compact-wide-inline-lyrics-$nowPlayingVisualKey',
                          ),
                          songId: playback.currentSongId!,
                          maxSize: artMaxSize,
                        )
                      : KeyedSubtree(
                          key: const ValueKey<String>('compact-wide-art-shell'),
                          child: compactWideArtSwitcher,
                        ),
                );

          // Car layout: all content (track info + controls) is centered
          // vertically as a single unit so it aligns with the album art
          // center. Using mainAxisSize.min + Center avoids the large dead
          // spaces that a Spacer approach creates on the 628dp usable height.
          // Spacing between the two groups (info and playback) is proportional
          // to the available height so the layout breathes on larger screens.
          final vSpacing = (constraints.maxHeight * 0.06).clamp(10.0, 28.0);
          final infoColumn = Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: songSwapTransitionBuilder,
                    child: _TrackInfo(
                      key: ValueKey<String>(
                        'compact-wide-track-$nowPlayingVisualKey',
                      ),
                      title: title,
                      artist: artist,
                      album: album,
                      compact: true,
                      onTitleTap: isRadio
                          ? (radioMeta?.nowPlayingTitle != null &&
                                    radioMeta!.nowPlayingTitle!.isNotEmpty
                                ? () {
                                    ref
                                        .read(
                                          searchFilterProvider.notifier,
                                        )
                                        .select(SearchResultType.songs);
                                    NavService.goToSearch(
                                      context,
                                      ref,
                                      radioMeta.nowPlayingTitle!,
                                    );
                                  }
                                : null)
                          : null,
                      artistLinks: isRadio
                          ? (radioMeta?.nowPlayingArtist != null &&
                                    radioMeta!.nowPlayingArtist!.isNotEmpty
                                ? _splitArtists(radioMeta.nowPlayingArtist!)
                                      .map(
                                        (name) => (
                                          name: name,
                                          onTap: () {
                                            ref
                                                .read(
                                                  searchFilterProvider.notifier,
                                                )
                                                .select(
                                                  SearchResultType.artists,
                                                );
                                            NavService.goToSearch(
                                              context,
                                              ref,
                                              name,
                                            );
                                          },
                                        ),
                                      )
                                      .toList()
                                : null)
                          : null,
                      onArtistTap: isRadio
                          ? null
                          : (resolvedArtistId != null
                                ? () => NavService.goToArtist(
                                    context,
                                    ref,
                                    resolvedArtistId,
                                  )
                                : (song?.artistName != null &&
                                          song!.artistName!.isNotEmpty
                                      ? () => NavService.goToSearch(
                                          context,
                                          ref,
                                          song.artistName!,
                                        )
                                      : null)),
                      onAlbumTap: isRadio
                          ? null
                          : (song?.albumId != null && song!.albumId!.isNotEmpty
                                ? () => NavService.goToAlbum(
                                    context,
                                    ref,
                                    song.albumId!,
                                  )
                                : null),
                    ),
                  ),
                  if (!isRadio) ...<Widget>[
                    SizedBox(height: vSpacing * 0.4),
                    _NowPlayingInfoPanel(
                      key: ValueKey<String>(
                        'compact-wide-info-$nowPlayingVisualKey',
                      ),
                      song: song,
                      album: albumDetails,
                      playback: playback,
                      currentMediaItem: currentMediaItem,
                      playbackSpeed: playbackSpeed,
                    ),
                    SizedBox(height: vSpacing),
                    _SeekBar(playback: playback),
                    SizedBox(height: vSpacing * 0.6),
                  ] else ...<Widget>[
                    SizedBox(height: vSpacing),
                  ],
                  _TransportControls(
                    playback: playback,
                    isRadio: isRadio,
                    showVolumeControl: false,
                    onSkipPrevious: _handleManualPreviousButton,
                    onSkipNext: _handleManualNextButton,
                  ),
                  if (!isRadio) ...<Widget>[
                    SizedBox(height: vSpacing * 0.6),
                    _ActionRow(
                      song: song,
                      songId: playback.currentSongId,
                      isLiked: playback.isCurrentSongLiked,
                      showLyrics: _showLyrics || _showWideFullscreenLyrics,
                      onLyricsToggle: playback.currentSongId == null
                          ? null
                          : () => _updateWideOverlayState(() {
                              _showWideFullscreenLyrics = false;
                              _showLyrics = !_showLyrics;
                            }),
                      wideEmbeddedMode: true,
                      onOpenQueuePanel: _showQueuePanel,
                      onOpenSettingsPanel: () => _updateWideOverlayState(() {
                        _showWideFullscreenLyrics = false;
                        _widePanel = _WideNowPlayingPanel.settings;
                      }),
                      onOpenMixPanel: () => _updateWideOverlayState(() {
                        _showWideFullscreenLyrics = false;
                        _widePanel = _WideNowPlayingPanel.mix;
                      }),
                    ),
                  ],
                ],
              ),
            ),
          );

          final compactPlayerPage = Padding(
            key: const ValueKey<String>('compact-wide-player-page'),
            padding: compactPadding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: artPaneWidth,
                  child: Center(child: coverOrLyrics),
                ),
                SizedBox(width: gap),
                Expanded(child: infoColumn),
              ],
            ),
          );

          Widget? compactOverlayPage;
          var compactOverlayKey = const ValueKey<String>(
            'compact-wide-overlay-none',
          );
          if (_showWideFullscreenLyrics && playback.currentSongId != null) {
            compactOverlayKey = const ValueKey<String>(
              'compact-wide-fullscreen-lyrics',
            );
            compactOverlayPage = _EmbeddedNowPlayingPanelScaffold(
              key: compactOverlayKey,
              title: l10n.nowPlayingLyrics,
              subtitle: title,
              onBack: () => _updateWideOverlayState(() {
                _showWideFullscreenLyrics = false;
              }),
              child: _EmbeddedFullscreenLyricsPanel(
                songId: playback.currentSongId!,
                playback: playback,
              ),
            );
          } else if (_widePanel == _WideNowPlayingPanel.queue) {
            compactOverlayKey = const ValueKey<String>('compact-wide-queue');
            compactOverlayPage = _CompactWideOverlaySheet(
              key: compactOverlayKey,
              title: l10n.queueTitle,
              showTopBar: false,
              onDismiss: () => _updateWideOverlayState(() {
                _widePanel = _WideNowPlayingPanel.none;
              }),
              child: QueueSheet(
                scrollController: _embeddedQueueScrollController,
                embeddedMode: true,
                onClose: () => _updateWideOverlayState(() {
                  _widePanel = _WideNowPlayingPanel.none;
                }),
              ),
            );
          } else if (_widePanel == _WideNowPlayingPanel.mix &&
              playback.currentSongId != null) {
            compactOverlayKey = const ValueKey<String>('compact-wide-mix');
            compactOverlayPage = _CompactWideOverlaySheet(
              key: compactOverlayKey,
              title: l10n.nowPlayingInstantMixLabel,
              onDismiss: () => _updateWideOverlayState(() {
                _widePanel = _WideNowPlayingPanel.none;
              }),
              child: _EmbeddedMixPanel(seedSongId: playback.currentSongId!),
            );
          } else if (_widePanel == _WideNowPlayingPanel.settings) {
            compactOverlayKey = const ValueKey<String>('compact-wide-settings');
            compactOverlayPage = _CompactWideOverlaySheet(
              key: compactOverlayKey,
              title: l10n.settingsTitle,
              onDismiss: () => _updateWideOverlayState(() {
                _widePanel = _WideNowPlayingPanel.none;
              }),
              child: _NowPlayingSettingsPanel(
                song: song,
                onCollapse: widget.onCollapse,
                fullscreenLyricsSongId: playback.currentSongId,
                fullscreenLyricsTitle: title,
                onOpenFullscreenLyrics: openFullscreenLyricsFromSettings,
              ),
            );
          }

          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Positioned.fill(child: compactPlayerPage),
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: compactOverlayPage == null,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    reverseDuration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    // _CompactWideOverlaySheet owns all its animation;
                    // the switcher just manages tree membership.
                    transitionBuilder: (child, animation) => child,
                    layoutBuilder: (currentChild, previousChildren) {
                      return Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          ...previousChildren,
                          if (currentChild != null) currentChild,
                        ],
                      );
                    },
                    child: compactOverlayPage == null
                        ? const SizedBox.shrink()
                        : KeyedSubtree(
                            key: compactOverlayKey,
                            child: compactOverlayPage,
                          ),
                  ),
                ),
              ),
            ],
          );
        }

        if (widget.wideEmbeddedMode &&
            !isSplitNowPlaying &&
            _showWideFullscreenLyrics &&
            playback.currentSongId != null) {
          return _EmbeddedNowPlayingPanelScaffold(
            key: const ValueKey<String>('wide-fullscreen-lyrics'),
            title: l10n.nowPlayingLyrics,
            subtitle: title,
            onBack: () => _updateWideOverlayState(() {
              _showWideFullscreenLyrics = false;
            }),
            child: _InlineLyrics(songId: playback.currentSongId!),
          );
        }
        if (widget.wideEmbeddedMode &&
            !isSplitNowPlaying &&
            _showWideFullscreenLyrics &&
            playback.currentSongId == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _updateWideOverlayState(() {
                _showWideFullscreenLyrics = false;
              });
            }
          });
        }

        if (!supportsSplitPanelOverlay &&
            _widePanel != _WideNowPlayingPanel.none) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _updateWideOverlayState(() {
                _widePanel = _WideNowPlayingPanel.none;
              });
            }
          });
        }

        final tightHeight = constraints.maxHeight < 640;
        final compactHeight = constraints.maxHeight < 760;
        final compactTransport =
            compactHeight || layoutMode == _NowPlayingLayoutMode.compact;
        final showDesktopTransportVolume =
            widget.wideEmbeddedMode &&
            resolveAdaptiveContextFor(context).desktopRuntime &&
            !compactTransport;
        // Focus Player Mode is not yet user-accessible; keep the flag false
        // so no toggle button appears anywhere until the feature is released.
        const showDesktopFocusPlayerToggle = false;
        final compactSpacing =
            tightHeight || layoutMode == _NowPlayingLayoutMode.compact;
        final splitGap =
            splitMetrics?.gap ?? (widget.wideEmbeddedMode ? 14.0 : 20.0);
        final horizontalPadding =
            splitMetrics?.outerPadding ??
            switch (layoutMode) {
              _NowPlayingLayoutMode.compact => 24.0,
              _NowPlayingLayoutMode.standard =>
                widget.wideEmbeddedMode ? 14.0 : 22.0,
              _NowPlayingLayoutMode.split =>
                widget.wideEmbeddedMode ? 8.0 : 18.0,
            };
        final topInset = isSplitNowPlaying && widget.wideEmbeddedMode
            ? 2.0
            : tightHeight
            ? 4.0
            : 8.0;
        final artToMetaGap = compactSpacing ? 8.0 : 16.0;
        final metadataBottomGap = isSplitNowPlaying && widget.wideEmbeddedMode
            ? 4.0
            : tightHeight
            ? 4.0
            : 8.0;
        final artMaxSize =
            splitMetrics?.artSize ??
            (layoutMode == _NowPlayingLayoutMode.standard
                ? math.min(
                    constraints.maxWidth - (horizontalPadding * 2),
                    constraints.maxHeight * (tightHeight ? 0.48 : 0.54),
                  )
                : math.min(
                    constraints.maxWidth - (horizontalPadding * 2),
                    constraints.maxHeight * (tightHeight ? 0.52 : 0.62),
                  ));
        final availableContentHeight = math.max(
          0.0,
          constraints.maxHeight - topInset - artToMetaGap - metadataBottomGap,
        );
        double artRegionHeight;
        if (availableContentHeight <= 0) {
          artRegionHeight = 0;
        } else {
          final minMetadataHeight = compactSpacing ? 230.0 : 280.0;
          final minArtHeight = compactSpacing ? 210.0 : 250.0;
          final targetArtShare = switch (layoutMode) {
            _NowPlayingLayoutMode.compact => 0.56,
            _NowPlayingLayoutMode.standard => 0.53,
            _NowPlayingLayoutMode.split => 0.5,
          };
          final preferredArtHeight = math.min(
            artMaxSize + (compactSpacing ? 4.0 : 10.0),
            availableContentHeight * targetArtShare,
          );
          final maxArtHeight = math.max(
            minArtHeight,
            availableContentHeight - minMetadataHeight,
          );
          artRegionHeight = maxArtHeight <= minArtHeight
              ? maxArtHeight
              : preferredArtHeight.clamp(minArtHeight, maxArtHeight);
        }
        final metadataRegionHeight = math.max(
          0.0,
          availableContentHeight - artRegionHeight,
        );

        final showInlineLyrics =
            !widget.wideEmbeddedMode &&
            _showLyrics &&
            playback.currentSongId != null &&
            !supportsSplitPanelOverlay;
        final nowPlayingArtSwitcher = AnimatedSwitcher(
          duration: effectiveSongSwapArtDuration,
          switchInCurve: Curves.linear,
          switchOutCurve: Curves.linear,
          layoutBuilder: _coverArtSwitcherLayoutBuilder,
          transitionBuilder: effectiveSongSwapArtTransitionBuilder,
          child: _buildInteractiveSwipeableArt(
            key: ValueKey<String>('cover-$artVisualKey'),
            swipeEnabled: !isRadio,
            currentArt: hasCoverArtId
                ? _CoverArt(
                    coverArtId: coverArtId,
                    semanticLabel: title,
                    maxSize: artMaxSize,
                  )
                : (hasMediaArtUrl
                      ? _RadioCoverArt(artUrl: mediaArtUrl, maxSize: artMaxSize)
                      : _CoverArt(
                          coverArtId: null,
                          semanticLabel: title,
                          maxSize: artMaxSize,
                        )),
            previousArt: previousSong == null
                ? null
                : _CoverArt(
                    coverArtId: previousSong.coverArt,
                    semanticLabel: previousSong.title.isNotEmpty
                        ? previousSong.title
                        : l10n.nowPlayingUnknownTrack,
                    maxSize: artMaxSize,
                  ),
            nextArt: nextSong == null
                ? null
                : _CoverArt(
                    coverArtId: nextSong.coverArt,
                    semanticLabel: nextSong.title.isNotEmpty
                        ? nextSong.title
                        : l10n.nowPlayingUnknownTrack,
                    maxSize: artMaxSize,
                  ),
          ),
        );

        final artOrLyrics = isRadio
            ? _RadioCoverArt(
                artUrl: radioMeta?.nowPlayingArtUrl,
                maxSize: artMaxSize,
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: _coverArtSwitcherLayoutBuilder,
                transitionBuilder: _songSwapTransitionBuilder,
                child: showInlineLyrics
                    ? _InlineLyrics(
                        key: ValueKey<String>(
                          'inline-lyrics-$nowPlayingVisualKey',
                        ),
                        songId: playback.currentSongId!,
                        maxSize: artMaxSize,
                      )
                    : KeyedSubtree(
                        key: const ValueKey<String>('art-shell'),
                        child: nowPlayingArtSwitcher,
                      ),
              );

        final metadataTopChildren = <Widget>[
          if (widget.wideEmbeddedMode)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                l10n.nowPlayingTitle,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: songSwapTransitionBuilder,
            child: _TrackInfo(
              key: ValueKey<String>('track-info-$nowPlayingVisualKey'),
              title: title,
              artist: artist,
              album: album,
              compact: compactSpacing,
              onTitleTap: isRadio
                  ? (radioMeta?.nowPlayingTitle != null &&
                            radioMeta!.nowPlayingTitle!.isNotEmpty
                        ? () {
                            ref
                                .read(searchFilterProvider.notifier)
                                .select(SearchResultType.songs);
                            NavService.goToSearch(
                              context,
                              ref,
                              radioMeta.nowPlayingTitle!,
                            );
                          }
                        : null)
                  : null,
              artistLinks: isRadio
                  ? (radioMeta?.nowPlayingArtist != null &&
                            radioMeta!.nowPlayingArtist!.isNotEmpty
                        ? _splitArtists(radioMeta.nowPlayingArtist!)
                              .map(
                                (name) => (
                                  name: name,
                                  onTap: () {
                                    ref
                                        .read(searchFilterProvider.notifier)
                                        .select(SearchResultType.artists);
                                    NavService.goToSearch(context, ref, name);
                                  },
                                ),
                              )
                              .toList()
                        : null)
                  : null,
              onArtistTap: isRadio
                  ? null
                  : (resolvedArtistId != null
                        ? () => NavService.goToArtist(
                            context,
                            ref,
                            resolvedArtistId,
                          )
                        : (song?.artistName != null &&
                                  song!.artistName!.isNotEmpty
                              ? () => NavService.goToSearch(
                                  context,
                                  ref,
                                  song.artistName!,
                                )
                              : null)),
              onAlbumTap: isRadio
                  ? null
                  : (song?.albumId != null && song!.albumId!.isNotEmpty
                        ? () =>
                              NavService.goToAlbum(context, ref, song.albumId!)
                        : null),
            ),
          ),
          if (!isRadio) ...[
            SizedBox(height: isSplitNowPlaying ? (compactHeight ? 8 : 10) : 12),
            _NowPlayingInfoPanel(
              key: ValueKey<String>('info-panel-$nowPlayingVisualKey'),
              song: song,
              album: albumDetails,
              playback: playback,
              currentMediaItem: currentMediaItem,
              playbackSpeed: playbackSpeed,
            ),
          ],
          SizedBox(height: isSplitNowPlaying ? (compactHeight ? 6 : 10) : 16),
          if (!isRadio) ...[
            _SeekBar(playback: playback),
            SizedBox(height: compactSpacing ? 6 : 8),
          ],
        ];

        final metadataBottom = Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _TransportControls(
              playback: playback,
              isRadio: isRadio,
              compact: compactTransport,
              showVolumeControl: showDesktopTransportVolume,
              showFocusPlayerToggle: showDesktopFocusPlayerToggle,
              onSkipPrevious: _handleManualPreviousButton,
              onSkipNext: _handleManualNextButton,
            ),
            SizedBox(height: compactSpacing ? 4 : 8),
            if (!isRadio)
              _ActionRow(
                song: song,
                songId: playback.currentSongId,
                isLiked: playback.isCurrentSongLiked,
                showLyrics: _showLyrics || _showWideFullscreenLyrics,
                onOpenSettingsSheet: !supportsSplitPanelOverlay
                    ? () => _showNowPlayingSettingsSheet(
                        context,
                        ref,
                        song,
                        fullscreenLyricsSongId: playback.currentSongId,
                        fullscreenLyricsTitle: playback.currentSongId == null
                            ? null
                            : title,
                      )
                    : null,
                onLyricsToggle: playback.currentSongId == null
                    ? null
                    : () {
                        if (fullscreenLyricsMode) {
                          unawaited(
                            _openLyricsFullscreen(
                              context,
                              playback.currentSongId!,
                              title,
                            ),
                          );
                          return;
                        }
                        if (widget.wideEmbeddedMode &&
                            _widePanel != _WideNowPlayingPanel.none) {
                          _updateWideOverlayState(() {
                            _widePanel = _WideNowPlayingPanel.none;
                            _showWideFullscreenLyrics = false;
                            _showLyrics = !_showLyrics;
                          });
                          return;
                        }
                        setState(() {
                          _showWideFullscreenLyrics = false;
                          _showLyrics = !_showLyrics;
                        });
                      },
                wideEmbeddedMode: supportsSplitPanelOverlay,
                onOpenQueuePanel: supportsSplitPanelOverlay
                    ? () => _updateWideOverlayState(() {
                        _showWideFullscreenLyrics = false;
                        _widePanel = _WideNowPlayingPanel.queue;
                      })
                    : null,
                onOpenSettingsPanel: supportsSplitPanelOverlay
                    ? () => _updateWideOverlayState(() {
                        _showWideFullscreenLyrics = false;
                        _widePanel = _WideNowPlayingPanel.settings;
                      })
                    : null,
                onOpenMixPanel: supportsSplitPanelOverlay
                    ? () => _updateWideOverlayState(() {
                        _showWideFullscreenLyrics = false;
                        _widePanel = _WideNowPlayingPanel.mix;
                      })
                    : null,
              ),
          ],
        );
        final metadataTop = Column(
          mainAxisSize: MainAxisSize.min,
          children: metadataTopChildren,
        );

        Widget buildMetadataPane({required bool splitLayout}) {
          final shouldFlattenToSingleScroll =
              constraints.maxHeight < (splitLayout ? 620 : 700);
          if (shouldFlattenToSingleScroll) {
            return SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  metadataTop,
                  SizedBox(height: compactSpacing ? 10 : 14),
                  metadataBottom,
                ],
              ),
            );
          }

          return Column(
            children: <Widget>[
              Expanded(
                child: LayoutBuilder(
                  builder: (context, topConstraints) => SingleChildScrollView(
                    padding: EdgeInsets.zero,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: topConstraints.maxHeight,
                      ),
                      child: Align(
                        alignment: splitLayout
                            ? Alignment.topCenter
                            : Alignment.center,
                        child: metadataTop,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: compactSpacing ? 10 : 14),
              metadataBottom,
            ],
          );
        }

        if (!isSplitNowPlaying) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: Column(
              children: <Widget>[
                SizedBox(height: topInset),
                SizedBox(
                  height: artRegionHeight,
                  child: Center(child: artOrLyrics),
                ),
                SizedBox(height: artToMetaGap),
                SizedBox(
                  height: metadataRegionHeight,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: metadataBottomGap),
                    child: buildMetadataPane(splitLayout: false),
                  ),
                ),
              ],
            ),
          );
        }

        final colorScheme = Theme.of(context).colorScheme;
        final metrics = splitMetrics;
        final rightPaneWidth = metrics.rightPaneWidth;
        final splitCoverArtMaxSize = math
            .min(rightPaneWidth - 56, constraints.maxHeight * 0.36)
            .clamp(170.0, 340.0);
        final lyricsPane = DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                colorScheme.surfaceContainerLowest,
                colorScheme.surfaceContainerLow,
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: playback.currentSongId == null
                ? Center(
                    child: Text(
                      l10n.lyricsNoneAvailable,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : _InlineLyrics(songId: playback.currentSongId!),
          ),
        );
        final splitTopInfo = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: songSwapTransitionBuilder,
            child: _NowPlayingInfoGrid(
              key: ValueKey<String>('split-top-info-$nowPlayingVisualKey'),
              song: song,
              album: albumDetails,
              playback: playback,
              currentMediaItem: currentMediaItem,
              playbackSpeed: playbackSpeed,
            ),
          ),
        );
        final splitCoverArt = AnimatedSwitcher(
          duration: effectiveSongSwapArtDuration,
          switchInCurve: Curves.linear,
          switchOutCurve: Curves.linear,
          layoutBuilder: _coverArtSwitcherLayoutBuilder,
          transitionBuilder: effectiveSongSwapArtTransitionBuilder,
          child: isRadio
              ? _RadioCoverArt(
                  key: ValueKey<String>('split-radio-art-$artVisualKey'),
                  artUrl: radioMeta?.nowPlayingArtUrl,
                  maxSize: splitCoverArtMaxSize,
                )
              : _buildInteractiveSwipeableArt(
                  key: ValueKey<String>('split-cover-$artVisualKey'),
                  swipeEnabled: !isRadio,
                  currentArt: hasCoverArtId
                      ? _CoverArt(
                          coverArtId: coverArtId,
                          semanticLabel: title,
                          maxSize: splitCoverArtMaxSize,
                        )
                      : (hasMediaArtUrl
                            ? _RadioCoverArt(
                                artUrl: mediaArtUrl,
                                maxSize: splitCoverArtMaxSize,
                              )
                            : _CoverArt(
                                coverArtId: null,
                                semanticLabel: title,
                                maxSize: splitCoverArtMaxSize,
                              )),
                  previousArt: previousSong == null
                      ? null
                      : _CoverArt(
                          coverArtId: previousSong.coverArt,
                          semanticLabel: previousSong.title.isNotEmpty
                              ? previousSong.title
                              : l10n.nowPlayingUnknownTrack,
                          maxSize: splitCoverArtMaxSize,
                        ),
                  nextArt: nextSong == null
                      ? null
                      : _CoverArt(
                          coverArtId: nextSong.coverArt,
                          semanticLabel: nextSong.title.isNotEmpty
                              ? nextSong.title
                              : l10n.nowPlayingUnknownTrack,
                          maxSize: splitCoverArtMaxSize,
                        ),
                ),
        );
        final splitBottomStack = Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Center(child: splitCoverArt),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: songSwapTransitionBuilder,
              child: _TrackInfo(
                key: ValueKey<String>('split-track-info-$nowPlayingVisualKey'),
                title: title,
                artist: artist,
                album: album,
                compact: true,
                onTitleTap: isRadio
                    ? (radioMeta?.nowPlayingTitle != null &&
                              radioMeta!.nowPlayingTitle!.isNotEmpty
                          ? () {
                              ref
                                  .read(searchFilterProvider.notifier)
                                  .select(SearchResultType.songs);
                              NavService.goToSearch(
                                context,
                                ref,
                                radioMeta.nowPlayingTitle!,
                              );
                            }
                          : null)
                    : null,
                artistLinks: isRadio
                    ? (radioMeta?.nowPlayingArtist != null &&
                              radioMeta!.nowPlayingArtist!.isNotEmpty
                          ? _splitArtists(radioMeta.nowPlayingArtist!)
                                .map(
                                  (name) => (
                                    name: name,
                                    onTap: () {
                                      ref
                                          .read(searchFilterProvider.notifier)
                                          .select(SearchResultType.artists);
                                      NavService.goToSearch(context, ref, name);
                                    },
                                  ),
                                )
                                .toList()
                          : null)
                    : null,
                onArtistTap: isRadio
                    ? null
                    : (resolvedArtistId != null
                          ? () => NavService.goToArtist(
                              context,
                              ref,
                              resolvedArtistId,
                            )
                          : (song?.artistName != null &&
                                    song!.artistName!.isNotEmpty
                                ? () => NavService.goToSearch(
                                    context,
                                    ref,
                                    song.artistName!,
                                  )
                                : null)),
                onAlbumTap: isRadio
                    ? null
                    : (song?.albumId != null && song!.albumId!.isNotEmpty
                          ? () => NavService.goToAlbum(
                              context,
                              ref,
                              song.albumId!,
                            )
                          : null),
              ),
            ),
            if (!isRadio) ...<Widget>[
              const SizedBox(height: 12),
              _SeekBar(playback: playback),
              const SizedBox(height: 8),
            ],
            _TransportControls(
              playback: playback,
              isRadio: isRadio,
              compact: compactTransport,
              showVolumeControl: showDesktopTransportVolume,
              showFocusPlayerToggle: showDesktopFocusPlayerToggle,
              onSkipPrevious: _handleManualPreviousButton,
              onSkipNext: _handleManualNextButton,
            ),
            const SizedBox(height: 8),
            if (!isRadio)
              _ActionRow(
                song: song,
                songId: playback.currentSongId,
                isLiked: playback.isCurrentSongLiked,
                showLyrics: false,
                onOpenSettingsSheet: !supportsSplitPanelOverlay
                    ? () => _showNowPlayingSettingsSheet(
                        context,
                        ref,
                        song,
                        fullscreenLyricsSongId: playback.currentSongId,
                        fullscreenLyricsTitle: playback.currentSongId == null
                            ? null
                            : title,
                      )
                    : null,
                onLyricsToggle: playback.currentSongId == null
                    ? null
                    : () => unawaited(
                        _openLyricsFullscreen(
                          context,
                          playback.currentSongId!,
                          title,
                        ),
                      ),
                wideEmbeddedMode: supportsSplitPanelOverlay,
                onOpenQueuePanel: supportsSplitPanelOverlay
                    ? () => _updateWideOverlayState(() {
                        _showWideFullscreenLyrics = false;
                        _widePanel = _WideNowPlayingPanel.queue;
                      })
                    : null,
                onOpenSettingsPanel: supportsSplitPanelOverlay
                    ? () => _updateWideOverlayState(() {
                        _showWideFullscreenLyrics = false;
                        _widePanel = _WideNowPlayingPanel.settings;
                      })
                    : null,
                onOpenMixPanel: supportsSplitPanelOverlay
                    ? () => _updateWideOverlayState(() {
                        _showWideFullscreenLyrics = false;
                        _widePanel = _WideNowPlayingPanel.mix;
                      })
                    : null,
              ),
          ],
        );
        final rightPaneContent = LayoutBuilder(
          builder: (context, rightConstraints) {
            final estimatedBottomHeight =
                splitCoverArtMaxSize + (isRadio ? 250 : 390);
            final canPinBottom =
                rightConstraints.maxHeight > estimatedBottomHeight + 64;
            if (!canPinBottom) {
              return SingleChildScrollView(
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    splitTopInfo,
                    const SizedBox(height: 14),
                    splitBottomStack,
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                splitTopInfo,
                const SizedBox(height: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, bottomConstraints) =>
                        SingleChildScrollView(
                          padding: EdgeInsets.zero,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: bottomConstraints.maxHeight,
                            ),
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: splitBottomStack,
                            ),
                          ),
                        ),
                  ),
                ),
              ],
            );
          },
        );
        String? rightPanePanelTitle;
        String? rightPanePanelSubtitle;
        var rightPanePanelHeightFactor = 0.6;
        Widget? rightPanePanelChild;
        var usePanelHeader = true;

        if (supportsSplitPanelOverlay) {
          if (_widePanel == _WideNowPlayingPanel.settings) {
            rightPanePanelTitle = l10n.settingsTitle;
            rightPanePanelHeightFactor = 0.52;
            rightPanePanelChild = _NowPlayingSettingsPanel(
              song: song,
              onCollapse: widget.onCollapse,
              fullscreenLyricsSongId: playback.currentSongId,
              fullscreenLyricsTitle: title,
              onOpenFullscreenLyrics: openFullscreenLyricsFromSettings,
            );
          } else if (_widePanel == _WideNowPlayingPanel.mix &&
              playback.currentSongId != null) {
            rightPanePanelTitle = l10n.nowPlayingInstantMixLabel;
            rightPanePanelHeightFactor = 0.62;
            rightPanePanelChild = _EmbeddedMixPanel(
              seedSongId: playback.currentSongId!,
            );
          } else if (_widePanel == _WideNowPlayingPanel.queue) {
            rightPanePanelTitle = l10n.queueTitle;
            rightPanePanelHeightFactor = 0.7;
            usePanelHeader = false;
            rightPanePanelChild = MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: QueueSheet(
                scrollController: _embeddedQueueScrollController,
                onClose: () => _updateWideOverlayState(() {
                  _widePanel = _WideNowPlayingPanel.none;
                }),
              ),
            );
          }
        }

        final rightPanePanelOverlay = rightPanePanelChild == null
            ? const SizedBox.shrink()
            : _EmbeddedRightPaneBottomSheet(
                key: ValueKey<String>('right-pane-panel-${_widePanel.name}'),
                title: rightPanePanelTitle,
                subtitle: rightPanePanelSubtitle,
                heightFactor: rightPanePanelHeightFactor,
                useHeader: usePanelHeader,
                onClose: () => _updateWideOverlayState(() {
                  _widePanel = _WideNowPlayingPanel.none;
                }),
                child: rightPanePanelChild,
              );

        Widget splitLayout = Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            topInset,
            horizontalPadding,
            metadataBottomGap,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(width: metrics.leftPaneWidth, child: lyricsPane),
              SizedBox(width: splitGap),
              SizedBox(
                width: rightPaneWidth,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: colorScheme.outlineVariant.withValues(
                              alpha: 0.5,
                            ),
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: colorScheme.shadow.withValues(alpha: 0.08),
                              blurRadius: 22,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                          child: rightPaneContent,
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        reverseDuration: const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        layoutBuilder: (currentChild, previousChildren) {
                          return Stack(
                            children: <Widget>[
                              if (currentChild != null) currentChild,
                            ],
                          );
                        },
                        transitionBuilder: (child, animation) {
                          final curved = CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOut,
                            reverseCurve: Curves.easeIn,
                          );
                          return ClipRect(
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, 0.08),
                                end: Offset.zero,
                              ).animate(curved),
                              child: child,
                            ),
                          );
                        },
                        child: rightPanePanelOverlay,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        if (widget.wideEmbeddedMode) {
          splitLayout = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: _handleWideVerticalDragStart,
            onVerticalDragUpdate: (details) =>
                _handleWideVerticalDragUpdate(details, splitLayout: true),
            onVerticalDragEnd: (details) =>
                _handleWideVerticalDragEnd(details, splitLayout: true),
            onVerticalDragCancel: _handleWideVerticalDragCancel,
            child: splitLayout,
          );
        }
        return splitLayout;
      },
    );
  }
}

class _CoverArt extends ConsumerWidget {
  const _CoverArt({this.coverArtId, this.semanticLabel, this.maxSize});

  final String? coverArtId;
  final String? semanticLabel;
  final double? maxSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final npShape = ref.watch(nowPlayingArtShapeProvider);
    final npRadius = coverArtShapeToRadius(npShape);
    final explicitMaxSize = maxSize;
    if (explicitMaxSize != null) {
      final artSize = explicitMaxSize.clamp(180.0, 680.0);
      return CoverArtImage(
        coverArtId: coverArtId,
        size: kCoverArtStandardSize,
      );
    }

    final mq = MediaQuery.of(context).size;
    final widthBased = mq.width - 48;
    final heightBased = mq.height * 0.52;
    final baseSize = (widthBased < heightBased ? widthBased : heightBased);
    final artSize = baseSize.clamp(180.0, 600.0);

    return CoverArtImage(
      coverArtId: coverArtId,
      size: kCoverArtStandardSize,
      semanticLabel: semanticLabel,
    );
  }
}

class _RadioCoverArt extends ConsumerWidget {
  const _RadioCoverArt({super.key, this.artUrl, this.maxSize});

  final String? artUrl;
  final double? maxSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final npShape = ref.watch(nowPlayingArtShapeProvider);
    final npRadius = coverArtShapeToRadius(npShape);
    final explicitMaxSize = maxSize;
    if (explicitMaxSize != null) {
      final artSize = explicitMaxSize.clamp(180.0, 680.0);
      if (artUrl != null) {
        return ClipRRect(
          borderRadius: npRadius,
          child: CachedNetworkImage(
            imageUrl: artUrl!,
            width: artSize,
            height: artSize,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) =>
                _radioPlaceholder(context, artSize, npRadius),
          ),
        );
      }
      return _radioPlaceholder(context, artSize, npRadius);
    }

    final mq = MediaQuery.of(context).size;
    final widthBased = mq.width - 48;
    final heightBased = mq.height * 0.52;
    final baseSize = (widthBased < heightBased ? widthBased : heightBased);
    final artSize = baseSize.clamp(180.0, 600.0);

    if (artUrl != null) {
      return ClipRRect(
        borderRadius: npRadius,
        child: CachedNetworkImage(
          imageUrl: artUrl!,
          width: artSize,
          height: artSize,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) =>
              _radioPlaceholder(context, artSize, npRadius),
        ),
      );
    }

    return _radioPlaceholder(context, artSize, npRadius);
  }

  Widget _radioPlaceholder(
    BuildContext context,
    double size,
    BorderRadius borderRadius,
  ) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: borderRadius,
      ),
      child: Icon(
        Icons.radio,
        size: size * 0.4,
        color: Theme.of(context).colorScheme.onPrimaryContainer,
      ),
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({
    super.key,
    required this.title,
    required this.artist,
    required this.album,
    this.compact = false,
    this.onTitleTap,
    this.onArtistTap,
    this.onAlbumTap,
    this.artistLinks,
  });

  final String title;
  final String artist;
  final String album;
  final bool compact;
  final VoidCallback? onTitleTap;

  /// Used when the artist is a single entity (regular tracks, non-split radio).
  final VoidCallback? onArtistTap;
  final VoidCallback? onAlbumTap;

  /// When non-null, the artist row renders each entry as an individual
  /// tappable link separated by commas. Takes precedence over [onArtistTap].
  final List<_ArtistLink>? artistLinks;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final links = artistLinks;
    return Column(
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTitleTap,
          child: Text(
            title,
            style: textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              fontSize: compact ? 20 : null,
              color: onTitleTap != null ? colorScheme.primary : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
        SizedBox(height: compact ? 2 : 4),
        if (links != null && links.isNotEmpty)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 0,
            runSpacing: 0,
            children: [
              for (final (i, link) in links.indexed) ...<Widget>[
                if (i > 0)
                  Text(
                    ', ',
                    style: textTheme.bodyLarge?.copyWith(
                      fontSize: compact ? 15 : null,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: link.onTap,
                  child: Text(
                    link.name,
                    style: textTheme.bodyLarge?.copyWith(
                      fontSize: compact ? 15 : null,
                      color: link.onTap != null
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          )
        else
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onArtistTap,
            child: Text(
              artist,
              style: textTheme.bodyLarge?.copyWith(
                fontSize: compact ? 15 : null,
                color: onArtistTap != null
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        SizedBox(height: compact ? 1 : 2),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onAlbumTap,
          child: Text(
            album,
            style: textTheme.bodyMedium?.copyWith(
              fontSize: compact ? 13 : null,
              color: onAlbumTap != null
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class _NowPlayingInfoPanel extends ConsumerStatefulWidget {
  const _NowPlayingInfoPanel({
    super.key,
    required this.song,
    required this.album,
    required this.playback,
    required this.currentMediaItem,
    required this.playbackSpeed,
  });

  final SongsTableData? song;
  final AlbumsTableData? album;
  final PlaybackSnapshot playback;
  final MediaItem? currentMediaItem;
  final double playbackSpeed;

  @override
  ConsumerState<_NowPlayingInfoPanel> createState() =>
      _NowPlayingInfoPanelState();
}

class _NowPlayingInfoPanelState extends ConsumerState<_NowPlayingInfoPanel> {
  int _pageIndex = 0;
  bool _showInlineRatingEditor = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final pages = _buildNowPlayingInfoPages(
      l10n: l10n,
      song: widget.song,
      album: widget.album,
      playback: widget.playback,
      currentMediaItem: widget.currentMediaItem,
      playbackSpeed: widget.playbackSpeed,
    );
    final activeIndex = _pageIndex % pages.length;
    final page = pages[activeIndex];
    final colors = Theme.of(context).colorScheme;
    final currentSongId = widget.song?.id;
    final inlineRating = currentSongId == null
        ? null
        : ref.watch(songRatingProvider(currentSongId)).asData?.value;
    final isRatingPage = page.isRatingPage;
    final showInlineEditor =
        isRatingPage && _showInlineRatingEditor && currentSongId != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => setState(() {
          _pageIndex = (_pageIndex + 1) % pages.length;
          _showInlineRatingEditor = false;
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: <Widget>[
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: Row(
                  key: ValueKey<String>(
                    '${page.semanticLabel}:${page.value}:$showInlineEditor',
                  ),
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      page.icon,
                      size: 14,
                      color: colors.onSurfaceVariant.withValues(alpha: 0.72),
                    ),
                    const SizedBox(width: 6),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: showInlineEditor ? 132 : 210,
                        ),
                        child: showInlineEditor
                            ? RatingWidget(
                                rating: inlineRating,
                                compact: true,
                                onChanged: (next) {
                                  setState(
                                    () => _showInlineRatingEditor = false,
                                  );
                                  unawaited(
                                    setSongRating(
                                      currentSongId,
                                      next,
                                      ref,
                                    ).catchError((_) {
                                      if (context.mounted) {
                                        AppNoticeMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              l10n.ratingUpdateFailed,
                                            ),
                                          ),
                                        );
                                      }
                                    }),
                                  );
                                },
                              )
                            : GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onLongPress:
                                    isRatingPage && currentSongId != null
                                    ? () {
                                        setState(
                                          () => _showInlineRatingEditor = true,
                                        );
                                      }
                                    : null,
                                child: Text(
                                  page.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: colors.onSurfaceVariant
                                            .withValues(alpha: 0.82),
                                      ),
                                ),
                              ),
                      ),
                    ),
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

class _NowPlayingInfoPage {
  const _NowPlayingInfoPage({
    required this.icon,
    required this.semanticLabel,
    required this.value,
    this.isRatingPage = false,
  });

  final IconData icon;
  final String semanticLabel;
  final String value;
  final bool isRatingPage;
}

List<_NowPlayingInfoPage> _buildNowPlayingInfoPages({
  required AppLocalizations l10n,
  required SongsTableData? song,
  required AlbumsTableData? album,
  required PlaybackSnapshot playback,
  required MediaItem? currentMediaItem,
  required double playbackSpeed,
}) {
  return <_NowPlayingInfoPage>[
    _NowPlayingInfoPage(
      icon: Icons.info_outline,
      semanticLabel: l10n.nowPlayingAudioQuality,
      value: _formatAudioQuality(song: song, mediaItem: currentMediaItem),
    ),
    _NowPlayingInfoPage(
      icon: Icons.queue_music_outlined,
      semanticLabel: l10n.queueTitle,
      value: _formatQueuePosition(l10n, playback),
    ),
    _NowPlayingInfoPage(
      icon: Icons.calendar_today_outlined,
      semanticLabel: l10n.nowPlayingReleaseDate,
      value: _formatReleaseDate(song, album),
    ),
    _NowPlayingInfoPage(
      icon: Icons.speed_outlined,
      semanticLabel: l10n.playbackSettingsPlaybackSpeedLabel,
      value: _formatPlaybackRate(playbackSpeed),
    ),
    _NowPlayingInfoPage(
      icon: Icons.star_border,
      semanticLabel: l10n.ratingTitle,
      value: _formatPreferenceSummary(l10n, song),
      isRatingPage: true,
    ),
  ];
}

class _NowPlayingInfoGrid extends ConsumerWidget {
  const _NowPlayingInfoGrid({
    super.key,
    required this.song,
    required this.album,
    required this.playback,
    required this.currentMediaItem,
    required this.playbackSpeed,
  });

  final SongsTableData? song;
  final AlbumsTableData? album;
  final PlaybackSnapshot playback;
  final MediaItem? currentMediaItem;
  final double playbackSpeed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final pages = _buildNowPlayingInfoPages(
      l10n: l10n,
      song: song,
      album: album,
      playback: playback,
      currentMediaItem: currentMediaItem,
      playbackSpeed: playbackSpeed,
    );
    final infoPages = pages.where((page) => !page.isRatingPage).toList();
    _NowPlayingInfoPage? ratingPage;
    for (final page in pages) {
      if (page.isRatingPage) {
        ratingPage = page;
        break;
      }
    }
    final colors = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: colors.onSurfaceVariant.withValues(alpha: 0.86),
      fontWeight: FontWeight.w600,
    );
    final valueStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: colors.onSurface,
      fontWeight: FontWeight.w500,
    );
    final currentSongId = song?.id;
    final currentRating = currentSongId == null
        ? null
        : ref.watch(songRatingProvider(currentSongId)).asData?.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < infoPages.length; i += 2) ...<Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: _NowPlayingInfoGridCell(
                  page: infoPages[i],
                  labelStyle: labelStyle,
                  valueStyle: valueStyle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: i + 1 < infoPages.length
                    ? _NowPlayingInfoGridCell(
                        page: infoPages[i + 1],
                        labelStyle: labelStyle,
                        valueStyle: valueStyle,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          if (i + 2 < infoPages.length) const SizedBox(height: 8),
        ],
        if (ratingPage != null) ...<Widget>[
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Icon(
                ratingPage.icon,
                size: 14,
                color: colors.onSurfaceVariant.withValues(alpha: 0.72),
              ),
              const SizedBox(width: 8),
              Text(ratingPage.semanticLabel, style: labelStyle),
            ],
          ),
          const SizedBox(height: 6),
          if (currentSongId != null)
            Align(
              alignment: Alignment.centerLeft,
              child: RatingWidget(
                rating: currentRating,
                compact: true,
                onChanged: (next) {
                  unawaited(
                    setSongRating(currentSongId, next, ref).catchError((_) {
                      if (context.mounted) {
                        AppNoticeMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l10n.ratingUpdateFailed)),
                        );
                      }
                    }),
                  );
                },
              ),
            )
          else
            Text(
              ratingPage.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valueStyle,
            ),
        ],
      ],
    );
  }
}

class _NowPlayingInfoGridCell extends StatelessWidget {
  const _NowPlayingInfoGridCell({
    required this.page,
    required this.labelStyle,
    required this.valueStyle,
  });

  final _NowPlayingInfoPage page;
  final TextStyle? labelStyle;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          page.icon,
          size: 14,
          color: colors.onSurfaceVariant.withValues(alpha: 0.72),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                page.semanticLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
              const SizedBox(height: 2),
              Text(
                page.value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: valueStyle,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _formatAudioQuality({
  required SongsTableData? song,
  required MediaItem? mediaItem,
}) {
  final extras = mediaItem?.extras;
  final resolvedFormat = (extras?['resolvedFormat'] as String?)?.trim();
  final transcodingApplied = (extras?['transcodingApplied'] as bool?) ?? false;
  final formatLabel =
      _formatAudioFormatLabel(
        resolvedFormat,
        isTranscoded: transcodingApplied,
      ) ??
      song?.suffix?.trim().toUpperCase() ??
      _inferAudioFormat(song?.contentType);
  final bitRate = (extras?['resolvedBitRate'] as int?) ?? song?.bitRate;
  final sampleRate = _readSampleRateFromExtras(extras) ?? song?.sampleRate;
  final descriptor = transcodingApplied ? 'Transcoded' : null;

  final parts = <String>[
    ?descriptor,
    if (formatLabel != null && formatLabel.isNotEmpty) formatLabel,
    if (bitRate != null && bitRate > 0) _formatBitRate(bitRate),
    if (sampleRate != null && sampleRate > 0) _formatSampleRate(sampleRate),
  ];

  if (parts.isEmpty) {
    return '-';
  }
  return parts.join(' • ');
}

int? _readSampleRateFromExtras(Map<String, dynamic>? extras) {
  if (extras == null || extras.isEmpty) {
    return null;
  }

  const keys = <String>[
    'resolvedSampleRate',
    'sampleRate',
    'samplingRate',
    'sample_rate',
    'sampling_rate',
  ];

  for (final key in keys) {
    final raw = extras[key];
    if (raw == null) {
      continue;
    }
    if (raw is int) {
      return raw > 0 ? raw : null;
    }
    if (raw is double) {
      final rounded = raw.round();
      return rounded > 0 ? rounded : null;
    }
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed > 0) {
        return parsed;
      }
      final parsedDouble = double.tryParse(raw.trim());
      if (parsedDouble != null) {
        final rounded = parsedDouble.round();
        if (rounded > 0) {
          return rounded;
        }
      }
    }
  }

  return null;
}

String? _formatAudioFormatLabel(String? format, {required bool isTranscoded}) {
  final normalized = format?.trim();
  if (normalized != null && normalized.isNotEmpty) {
    if (normalized.toLowerCase() == 'transcoded') {
      return 'Transcoded';
    }
    return normalized.toUpperCase();
  }
  if (isTranscoded) {
    return 'Transcoded';
  }
  return null;
}

String? _inferAudioFormat(String? contentType) {
  if (contentType == null || !contentType.contains('/')) {
    return null;
  }
  final subtype = contentType.split('/').last.trim();
  if (subtype.isEmpty) {
    return null;
  }
  return subtype.toUpperCase();
}

String _formatBitRate(int bitRate) {
  if (bitRate >= 1024) {
    final mbps = bitRate / 1024;
    final text = mbps % 1 == 0
        ? mbps.toStringAsFixed(0)
        : mbps.toStringAsFixed(1);
    return '$text Mb/s';
  }
  return '$bitRate Kb/s';
}

String _formatSampleRate(int sampleRateHz) {
  final sampleRateKhz = sampleRateHz / 1000;
  final text = sampleRateKhz % 1 == 0
      ? sampleRateKhz.toStringAsFixed(0)
      : sampleRateKhz.toStringAsFixed(1);
  return '$text kHz';
}

String _formatReleaseDate(SongsTableData? song, AlbumsTableData? album) {
  final createdAt = song?.createdAt;
  if (createdAt != null) {
    return _formatDate(createdAt);
  }
  final year = album?.year;
  if (year != null) {
    return year.toString();
  }
  return '-';
}

String _formatQueuePosition(AppLocalizations l10n, PlaybackSnapshot playback) {
  final total = playback.queueSongIds.length;
  if (total <= 0) {
    return '-';
  }

  final current = ((playback.currentIndex ?? 0) + 1).clamp(1, total);
  return l10n.nowPlayingQueuePosition(current, total);
}

String _formatDate(DateTime date) {
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  return '$day/$month/${date.year}';
}

String _formatPlaybackRate(double playbackSpeed) {
  if ((playbackSpeed - 1).abs() < 0.001) {
    return '-';
  }
  final speedValue = formatPlaybackSpeed(playbackSpeed).replaceAll('×', '');
  return 'x$speedValue';
}

const _kSeekSemanticsStepMs = 10000;

class _SeekBar extends ConsumerStatefulWidget {
  const _SeekBar({required this.playback});

  final PlaybackSnapshot playback;

  @override
  ConsumerState<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<_SeekBar> {
  double? _draggingValue;

  @override
  Widget build(BuildContext context) {
    final position =
        ref.watch(playbackPositionProvider).asData?.value ??
        widget.playback.position;
    final duration = widget.playback.duration;
    final durationMs = duration.inMilliseconds;
    final positionMs = position.inMilliseconds;

    final sliderValue =
        _draggingValue ??
        (durationMs > 0
            ? positionMs.toDouble().clamp(0, durationMs.toDouble())
            : 0.0);
    final sliderMax = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final sliderCurrentMs = sliderValue.round();
    final increasedMs = (sliderCurrentMs + _kSeekSemanticsStepMs).clamp(
      0,
      durationMs,
    );
    final decreasedMs = (sliderCurrentMs - _kSeekSemanticsStepMs).clamp(
      0,
      durationMs,
    );

    return Column(
      children: <Widget>[
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Semantics(
            container: true,
            slider: true,
            value:
                '${_formatDuration(Duration(milliseconds: sliderValue.round()))} of ${_formatDuration(duration)}',
            increasedValue:
                '${_formatDuration(Duration(milliseconds: increasedMs))} of ${_formatDuration(duration)}',
            decreasedValue:
                '${_formatDuration(Duration(milliseconds: decreasedMs))} of ${_formatDuration(duration)}',
            onIncrease: () {
              final handler = ref.read(audioHandlerProvider);
              if (handler == null) {
                return;
              }
              final currentMs = (_draggingValue ?? sliderValue).round();
              final targetMs = (currentMs + _kSeekSemanticsStepMs).clamp(
                0,
                durationMs,
              );
              setState(() => _draggingValue = null);
              unawaited(handler.seek(Duration(milliseconds: targetMs)));
            },
            onDecrease: () {
              final handler = ref.read(audioHandlerProvider);
              if (handler == null) {
                return;
              }
              final currentMs = (_draggingValue ?? sliderValue).round();
              final targetMs = (currentMs - _kSeekSemanticsStepMs).clamp(
                0,
                durationMs,
              );
              setState(() => _draggingValue = null);
              unawaited(handler.seek(Duration(milliseconds: targetMs)));
            },
            child: ExcludeSemantics(
              child: Slider(
                value: sliderValue.clamp(0, sliderMax),
                max: sliderMax,
                semanticFormatterCallback: (value) {
                  final pos = Duration(milliseconds: value.round());
                  return '${_formatDuration(pos)} of ${_formatDuration(widget.playback.duration)}';
                },
                onChanged: (value) {
                  setState(() => _draggingValue = value);
                },
                onChangeEnd: (value) {
                  setState(() => _draggingValue = null);
                  final handler = ref.read(audioHandlerProvider);
                  unawaited(
                    handler?.seek(Duration(milliseconds: value.round())),
                  );
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                _formatDuration(
                  _draggingValue != null
                      ? Duration(milliseconds: _draggingValue!.round())
                      : position,
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                _formatDuration(duration),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TransportControls extends ConsumerWidget {
  const _TransportControls({
    required this.playback,
    this.isRadio = false,
    this.compact = false,
    this.showVolumeControl = false,
    this.showFocusPlayerToggle = false,
    this.onSkipPrevious,
    this.onSkipNext,
  });

  final PlaybackSnapshot playback;
  final bool isRadio;
  final bool compact;
  final bool showVolumeControl;
  final bool showFocusPlayerToggle;
  final VoidCallback? onSkipPrevious;
  final VoidCallback? onSkipNext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPlaying = playback.playing;

    if (isRadio) {
      // Simplified radio transport: just play/pause and stop.
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (isDesktopRuntime)
            Tooltip(
              message: isPlaying ? l10n.nowPlayingPause : l10n.nowPlayingPlay,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: EdgeInsets.all(compact ? 12 : 16),
                ),
                onPressed: () {
                  final handler = ref.read(audioHandlerProvider);
                  if (isPlaying) {
                    unawaited(handler?.pause());
                  } else {
                    unawaited(handler?.play());
                  }
                },
                child: Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  size: compact ? 30 : 36,
                ),
              ),
            )
          else
            FilledButton(
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: EdgeInsets.all(compact ? 12 : 16),
              ),
              onPressed: () {
                final handler = ref.read(audioHandlerProvider);
                if (isPlaying) {
                  unawaited(handler?.pause());
                } else {
                  unawaited(handler?.play());
                }
              },
              child: Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                size: compact ? 30 : 36,
              ),
            ),
          SizedBox(width: compact ? 10 : 16),
          IconButton(
            icon: Icon(Icons.stop, size: compact ? 28 : 32),
            tooltip: l10n.radioStopStation,
            onPressed: () {
              final handler = ref.read(audioHandlerProvider);
              unawaited(handler?.stopRadio());
            },
          ),
        ],
      );
    }

    final shuffleOn = playback.shuffleMode == AudioServiceShuffleMode.all;
    final repeatMode = playback.repeatMode;
    final volume = ref.watch(playbackVolumeProvider);

    Future<void> setPlaybackVolume(
      double rawValue, {
      required String source,
      bool logChange = false,
    }) async {
      final volumeNotifier = ref.read(playbackVolumeProvider.notifier);
      final resolved = volumeNotifier.setVolume(rawValue);
      if (logChange) {
        AppLogger.debug(
          '[ACP_INPUT] volume source=$source value=${resolved.toStringAsFixed(2)}',
        );
      }
      await ref.read(audioHandlerProvider)?.setVolume(resolved);
    }

    Future<void> toggleMute({required String source}) async {
      final resolved = ref.read(playbackVolumeProvider.notifier).toggleMute();
      AppLogger.debug(
        '[ACP_INPUT] volume source=$source value=${resolved.toStringAsFixed(2)}',
      );
      await ref.read(audioHandlerProvider)?.setVolume(resolved);
    }

    String repeatTooltip;
    IconData repeatIcon;
    switch (repeatMode) {
      case AudioServiceRepeatMode.one:
        repeatTooltip = l10n.nowPlayingRepeatOne;
        repeatIcon = Icons.repeat_one;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        repeatTooltip = l10n.nowPlayingRepeatAll;
        repeatIcon = Icons.repeat;
      case AudioServiceRepeatMode.none:
        repeatTooltip = l10n.nowPlayingRepeatOff;
        repeatIcon = Icons.repeat;
    }

    final isRepeatActive = repeatMode != AudioServiceRepeatMode.none;

    // Minimum width required to display all transport buttons + volume slider.
    // Below this threshold the volume slider overflows the Row and is moved to
    // the settings modal instead.
    const transportVolumeMinWidth = 480.0;

    final row = LayoutBuilder(
      builder: (context, constraints) {
        final effectiveShowVolume =
            showVolumeControl &&
            constraints.maxWidth >= transportVolumeMinWidth;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton(
              icon: Icon(
                Icons.shuffle,
                color: shuffleOn ? Theme.of(context).colorScheme.primary : null,
              ),
              visualDensity: compact ? VisualDensity.compact : null,
              tooltip: shuffleOn
                  ? l10n.nowPlayingShuffle
                  : l10n.nowPlayingShuffleOff,
              onPressed: () {
                final handler = ref.read(audioHandlerProvider);
                final next = shuffleOn
                    ? AudioServiceShuffleMode.none
                    : AudioServiceShuffleMode.all;
                unawaited(handler?.setShuffleMode(next));
              },
            ),
            SizedBox(width: compact ? 4 : 8),
            IconButton(
              icon: Icon(Icons.skip_previous, size: compact ? 28 : 32),
              visualDensity: compact ? VisualDensity.compact : null,
              tooltip: l10n.nowPlayingPrevious,
              onPressed: () {
                if (onSkipPrevious != null) {
                  onSkipPrevious!.call();
                  return;
                }
                HapticFeedback.mediumImpact();
                final handler = ref.read(audioHandlerProvider);
                unawaited(handler?.skipToPrevious());
              },
            ),
            SizedBox(width: compact ? 4 : 8),
            if (isDesktopRuntime)
              Tooltip(
                message: isPlaying ? l10n.nowPlayingPause : l10n.nowPlayingPlay,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.all(compact ? 12 : 16),
                  ),
                  onPressed: () {
                    final handler = ref.read(audioHandlerProvider);
                    if (isPlaying) {
                      unawaited(handler?.pause());
                    } else {
                      unawaited(handler?.play());
                    }
                  },
                  child: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    size: compact ? 30 : 36,
                  ),
                ),
              )
            else
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: EdgeInsets.all(compact ? 12 : 16),
                ),
                onPressed: () {
                  final handler = ref.read(audioHandlerProvider);
                  if (isPlaying) {
                    unawaited(handler?.pause());
                  } else {
                    unawaited(handler?.play());
                  }
                },
                child: Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  size: compact ? 30 : 36,
                ),
              ),
            SizedBox(width: compact ? 4 : 8),
            IconButton(
              icon: Icon(Icons.skip_next, size: compact ? 28 : 32),
              visualDensity: compact ? VisualDensity.compact : null,
              tooltip: l10n.nowPlayingNext,
              onPressed: () {
                if (onSkipNext != null) {
                  onSkipNext!.call();
                  return;
                }
                HapticFeedback.mediumImpact();
                final handler = ref.read(audioHandlerProvider);
                unawaited(handler?.skipToNext());
              },
            ),
            SizedBox(width: compact ? 4 : 8),
            IconButton(
              icon: Icon(
                repeatIcon,
                color: isRepeatActive
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              visualDensity: compact ? VisualDensity.compact : null,
              tooltip: repeatTooltip,
              onPressed: () {
                final handler = ref.read(audioHandlerProvider);
                final next = switch (repeatMode) {
                  AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                  AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
                  AudioServiceRepeatMode.one => AudioServiceRepeatMode.none,
                  AudioServiceRepeatMode.group => AudioServiceRepeatMode.none,
                };
                unawaited(handler?.setRepeatMode(next));
              },
            ),
            if (showFocusPlayerToggle) ...<Widget>[
              SizedBox(width: compact ? 4 : 8),
              Consumer(
                builder: (context, ref, _) {
                  final focusMode = ref.watch(
                    desktopWindowControllerProvider.select(
                      (value) => value.isFocusPlayerMode,
                    ),
                  );
                  final busy = ref.watch(
                    desktopWindowControllerProvider.select(
                      (value) => value.isApplyingMode,
                    ),
                  );
                  final controller = ref.read(desktopWindowControllerProvider);
                  return IconButton(
                    key: const ValueKey<String>('desktopNowPlayingFocusButton'),
                    visualDensity: compact ? VisualDensity.compact : null,
                    tooltip: focusMode
                        ? 'Return to normal window'
                        : 'Enter Focus Player Mode',
                    onPressed: busy
                        ? null
                        : () => unawaited(controller.toggleFocusPlayerMode()),
                    icon: Icon(
                      focusMode
                          ? Icons.close_fullscreen_rounded
                          : Icons.fit_screen_rounded,
                    ),
                  );
                },
              ),
            ],
            if (effectiveShowVolume) ...<Widget>[
              SizedBox(width: compact ? 6 : 10),
              DesktopVolumeSlider(
                key: const ValueKey<String>('nowPlayingDesktopVolumeSlider'),
                volume: volume,
                compact: compact,
                onChanged: (value) => unawaited(
                  setPlaybackVolume(value, source: 'desktop_now_playing_live'),
                ),
                onChangeEnd: (value) => unawaited(
                  setPlaybackVolume(
                    value,
                    source: 'desktop_now_playing_settle',
                    logChange: true,
                  ),
                ),
                onMuteToggle: () =>
                    unawaited(toggleMute(source: 'desktop_now_playing_icon')),
              ),
            ],
          ],
        );
      },
    );
    return row;
  }
}

class _InlineLyrics extends ConsumerWidget {
  const _InlineLyrics({super.key, required this.songId, this.maxSize});

  final String songId;
  final double? maxSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final lyricsAsync = ref.watch(lyricsProvider(songId));
    final position =
        ref.watch(playbackPositionProvider).asData?.value ??
        ref.watch(playerStateProvider).position;

    Widget buildContent(LyricsResolution resolution) {
      return LyricsDisplayWidget(
        lyrics: resolution.lyrics,
        currentPosition: position,
        sourceLabel: _showExternalLyricsMeta(resolution)
            ? _lyricsSourceLabel(context, resolution.source)
            : null,
        attribution: _showExternalLyricsMeta(resolution)
            ? l10n.lyricsAttributionLrclib
            : null,
        onSeek: (seekPosition) {
          final handler = ref.read(audioHandlerProvider);
          handler?.seek(seekPosition);
        },
      );
    }

    Widget withOptionalSquareFrame(Widget child) {
      final size = maxSize;
      if (size == null) {
        return child;
      }
      final framedSize = size.clamp(180.0, 680.0);
      return SizedBox(width: framedSize, height: framedSize, child: child);
    }

    return lyricsAsync.when(
      data: (resolution) => withOptionalSquareFrame(buildContent(resolution)),
      loading: () => withOptionalSquareFrame(
        const Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) {
        final l10n = AppLocalizations.of(context)!;
        final String message;
        final VoidCallback? onRetry;

        if (error is LyricsUnsupportedException) {
          message = l10n.lyricsUnsupported;
          onRetry = null;
        } else if (error is LyricsNetworkException) {
          message = l10n.lyricsError;
          onRetry = () => ref.invalidate(lyricsProvider(songId));
        } else {
          message = l10n.lyricsNoneAvailable;
          onRetry = null;
        }

        final errorView = Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.commonRetry),
                ),
              ],
            ],
          ),
        );
        return withOptionalSquareFrame(errorView);
      },
    );
  }
}

class _FullscreenLyricsPage extends ConsumerWidget {
  const _FullscreenLyricsPage({required this.songId, required this.title});

  final String songId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final playback = ref.watch(playerStateProvider);
    final backLabel = MaterialLocalizations.of(context).backButtonTooltip;
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 108,
        leading: TextButton.icon(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
          label: Text(backLabel),
        ),
        title: Text(
          l10n.nowPlayingLyrics,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            children: <Widget>[
              Expanded(child: _InlineLyrics(songId: songId)),
              const SizedBox(height: 8),
              _TransportControls(
                playback: playback,
                isRadio: playback.isRadioMode,
                compact: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmbeddedFullscreenLyricsPanel extends ConsumerWidget {
  const _EmbeddedFullscreenLyricsPanel({
    required this.songId,
    required this.playback,
  });

  final String songId;
  final PlaybackSnapshot playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Column(
        children: <Widget>[
          Expanded(child: _InlineLyrics(songId: songId)),
          if (!playback.isRadioMode) ...<Widget>[
            const SizedBox(height: 8),
            _SeekBar(playback: playback),
          ],
          const SizedBox(height: 8),
          _TransportControls(
            playback: playback,
            isRadio: playback.isRadioMode,
            compact: true,
          ),
        ],
      ),
    );
  }
}

String _lyricsSourceLabel(BuildContext context, LyricsSource source) {
  final l10n = AppLocalizations.of(context)!;
  return switch (source) {
    LyricsSource.serverSynced => l10n.lyricsSourceServerSynced,
    LyricsSource.serverPlain => l10n.lyricsSourceServerPlain,
    LyricsSource.lrclibSynced => l10n.lyricsSourceLrclibSynced,
    LyricsSource.lrclibPlain => l10n.lyricsSourceLrclibPlain,
  };
}

bool _showExternalLyricsMeta(LyricsResolution resolution) {
  if (!resolution.isExternal) {
    return false;
  }
  if (resolution.lyrics.structuredLyrics.isNotEmpty) {
    final lines = resolution.lyrics.structuredLyrics.first.line;
    return lines.any((line) => (line.value ?? '').trim().isNotEmpty);
  }
  return (resolution.lyrics.value ?? '').trim().isNotEmpty;
}

String _formatPreferenceSummary(AppLocalizations l10n, SongsTableData? song) {
  if (song == null) return '-';
  final likedText = song.starred == null
      ? l10n.ratingNotLiked
      : l10n.actionLiked;
  final rating = song.userRating;
  if (rating == null || rating <= 0) {
    return '$likedText • ${l10n.ratingNoValue}';
  }
  return '$likedText • ${l10n.ratingValueShort(rating)}';
}

class _PlaybackSpeedSheet extends ConsumerStatefulWidget {
  const _PlaybackSpeedSheet({required this.initialSpeed});

  final double initialSpeed;

  @override
  ConsumerState<_PlaybackSpeedSheet> createState() =>
      _PlaybackSpeedSheetState();
}

class _PlaybackSpeedSheetState extends ConsumerState<_PlaybackSpeedSheet> {
  static const double _minPlaybackSpeed = 0.5;
  static const double _maxPlaybackSpeed = 2;
  double _speed = 1;
  bool _isSaving = false;
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    _speed = _normalizePlaybackSpeed(widget.initialSpeed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.playbackSettingsPlaybackSpeedLabel,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              formatPlaybackSpeed(_speed),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            Slider(
              value: _speed.clamp(_minPlaybackSpeed, _maxPlaybackSpeed),
              min: _minPlaybackSpeed,
              max: _maxPlaybackSpeed,
              divisions: 6,
              label: formatPlaybackSpeed(_speed),
              onChanged: _isSaving
                  ? null
                  : (value) {
                      setState(() => _speed = _normalizePlaybackSpeed(value));
                      _scheduleAutoSave();
                    },
            ),
            Text(
              l10n.playbackSettingsPlaybackSpeedSubtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton(
                  onPressed: _isSaving
                      ? null
                      : () {
                          setState(() => _speed = 1);
                          _scheduleAutoSave();
                        },
                  child: Text(l10n.playbackSettingsResetAction),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _isSaving
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _scheduleAutoSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 320),
      () => unawaited(_persistSpeed()),
    );
  }

  Future<void> _persistSpeed() async {
    if (_isSaving) {
      return;
    }
    setState(() => _isSaving = true);
    try {
      final settings =
          ref.read(appSettingsProvider).asData?.value ??
          const AppSettingsModel.defaults();
      await ref
          .read(settingsRepositoryProvider)
          .saveSettings(
            settings.copyWith(playbackSpeed: _normalizePlaybackSpeed(_speed)),
          );
      final handler = ref.read(audioHandlerProvider);
      await handler?.setPlaybackSpeed(_normalizePlaybackSpeed(_speed));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  double _normalizePlaybackSpeed(double value) {
    final clamped = value.clamp(_minPlaybackSpeed, _maxPlaybackSpeed);
    return (clamped * 4).round() / 4;
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}

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
            ? () => AppNoticeMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.remoteSourceInstantMixUnavailable)),
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
            ? () => AppNoticeMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.remoteSourceActionUnavailable)),
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

enum _WideNowPlayingPanel { none, settings, mix, queue }

enum _NowPlayingLayoutMode { compact, standard, split }

class _NowPlayingSplitMetrics {
  const _NowPlayingSplitMetrics({
    required this.outerPadding,
    required this.gap,
    required this.leftPaneWidth,
    required this.rightPaneWidth,
    required this.artSize,
  });

  final double outerPadding;
  final double gap;
  final double leftPaneWidth;
  final double rightPaneWidth;
  final double artSize;
}

class _EmbeddedRightPaneBottomSheet extends StatelessWidget {
  const _EmbeddedRightPaneBottomSheet({
    required this.heightFactor,
    required this.useHeader,
    required this.onClose,
    required this.child,
    this.title,
    this.subtitle,
    super.key,
  });

  final double heightFactor;
  final bool useHeader;
  final VoidCallback onClose;
  final Widget child;
  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.26)),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: heightFactor.clamp(0.42, 0.84),
            widthFactor: 1,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity > 280) {
                  onClose();
                }
              },
              child: Material(
                color: colorScheme.surfaceContainerHigh,
                elevation: 14,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                ),
                clipBehavior: Clip.antiAlias,
                child: useHeader
                    ? Column(
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Container(
                                  width: 34,
                                  height: 4,
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                    color: colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.4),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: <Widget>[
                                          if (title != null &&
                                              title!.isNotEmpty)
                                            Text(
                                              title!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style:
                                                  theme.textTheme.titleMedium,
                                            ),
                                          if (subtitle != null &&
                                              subtitle!.isNotEmpty)
                                            Text(
                                              subtitle!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: MaterialLocalizations.of(
                                        context,
                                      ).closeButtonTooltip,
                                      onPressed: onClose,
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(child: child),
                        ],
                      )
                    : child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmbeddedNowPlayingPanelScaffold extends StatefulWidget {
  const _EmbeddedNowPlayingPanelScaffold({
    required this.title,
    required this.onBack,
    required this.child,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onBack;
  final Widget child;

  @override
  State<_EmbeddedNowPlayingPanelScaffold> createState() =>
      _EmbeddedNowPlayingPanelScaffoldState();
}

class _EmbeddedNowPlayingPanelScaffoldState
    extends State<_EmbeddedNowPlayingPanelScaffold>
    with SingleTickerProviderStateMixin {
  static const double _dismissThreshold = 0.74;
  static const double _dismissFlingVelocity = 700;

  late final AnimationController _transitionController;
  bool _dismissRequested = false;

  @override
  void initState() {
    super.initState();
    _transitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 200),
      value: 0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          _transitionController.animateTo(1, curve: Curves.easeOutCubic),
        );
      }
    });
  }

  @override
  void dispose() {
    _transitionController.dispose();
    super.dispose();
  }

  double _viewportHeight() {
    final size = context.size;
    if (size != null && size.height > 0) {
      return size.height;
    }
    final media = MediaQuery.maybeOf(context);
    return media == null ? 1 : math.max(1, media.size.height);
  }

  void _applyDragDelta(double delta) {
    if (_dismissRequested) {
      return;
    }
    final height = _viewportHeight();
    final change = delta / height;
    _transitionController.value = (_transitionController.value - change).clamp(
      0,
      1,
    );
  }

  Future<void> _requestDismiss() async {
    if (_dismissRequested) {
      return;
    }
    _dismissRequested = true;
    await _transitionController.animateBack(0, curve: Curves.easeInCubic);
    if (!mounted) {
      return;
    }
    widget.onBack();
  }

  void _settleAfterGesture({double velocity = 0}) {
    if (_dismissRequested) {
      return;
    }
    final shouldDismiss =
        velocity > _dismissFlingVelocity ||
        _transitionController.value < _dismissThreshold;
    if (shouldDismiss) {
      unawaited(_requestDismiss());
      return;
    }
    unawaited(
      _transitionController.animateTo(
        1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (_dismissRequested) {
      return false;
    }
    if (notification is OverscrollNotification && notification.overscroll < 0) {
      _applyDragDelta(-notification.overscroll);
      return false;
    }
    if (notification is ScrollUpdateNotification &&
        notification.metrics.pixels >
            notification.metrics.minScrollExtent + 0.5 &&
        _transitionController.value < 0.995) {
      unawaited(
        _transitionController.animateTo(
          1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        ),
      );
      return false;
    }
    if (notification is ScrollEndNotification) {
      _settleAfterGesture();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _transitionController,
      builder: (context, child) {
        final progress = _transitionController.value.clamp(0, 1).toDouble();
        final eased = Curves.easeOutCubic.transform(progress);
        final opacity = Curves.easeOut.transform(progress);
        final translateY = (1 - eased) * 52;
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, translateY),
            child: child,
          ),
        );
      },
      child: Material(
        color: theme.colorScheme.surface,
        child: SafeArea(
          top: true,
          bottom: false,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) {
              final delta = details.primaryDelta;
              if (delta == null) {
                return;
              }
              _applyDragDelta(delta);
            },
            onVerticalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              _settleAfterGesture(velocity: math.max(0, velocity));
            },
            onVerticalDragCancel: _settleAfterGesture,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        onPressed: () {
                          unawaited(_requestDismiss());
                        },
                        icon: const Icon(Icons.arrow_back),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              widget.title,
                              style: theme.textTheme.titleMedium,
                            ),
                            if (widget.subtitle != null &&
                                widget.subtitle!.isNotEmpty)
                              Text(
                                widget.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleScrollNotification,
                    child: widget.child,
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

/// Full-height gesture-tracked slide-up overlay panel for compact-wide
/// landscape mode.
///
/// Slides in from the bottom with 1:1 finger tracking on the drag-handle
/// area, matching the gesture feel of [ExpandablePlayerSheet]. Dismisses via
/// downward swipe, fling, or the back-arrow button. Scroll-integrated dismiss
/// is also supported for panels whose [child] is a scrollable list.
class _CompactWideOverlaySheet extends StatefulWidget {
  const _CompactWideOverlaySheet({
    required this.title,
    required this.onDismiss,
    required this.child,
    this.showTopBar = true,
    super.key,
  });

  /// Velocity (px/s) that triggers an immediate fling-dismiss.
  static const double _flingThreshold = 300;

  /// Progress value (0–1) below which releasing the drag dismisses the panel.
  /// Lower value = more lenient (panel must be dragged >75% down to auto-dismiss).
  static const double _snapDismissThreshold = 0.25;

  final String title;
  final VoidCallback onDismiss;
  final Widget child;
  final bool showTopBar;

  @override
  State<_CompactWideOverlaySheet> createState() =>
      _CompactWideOverlaySheetState();
}

class _CompactWideOverlaySheetState extends State<_CompactWideOverlaySheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 260),
      value: 0,
    );
    _controller.addStatusListener(_onAnimationStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_controller.animateTo(1, curve: Curves.easeOutCubic));
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _dismissing) {
      widget.onDismiss();
    }
  }

  double _viewportHeight() {
    final size = context.size;
    if (size != null && size.height > 0) return size.height;
    final media = MediaQuery.maybeOf(context);
    return media == null ? 1.0 : math.max(1.0, media.size.height);
  }

  void _applyDragDelta(double delta) {
    if (_dismissing) return;
    final height = _viewportHeight();
    _controller.value = (_controller.value - delta / height).clamp(0.0, 1.0);
  }

  void _settleAfterDrag({double velocity = 0}) {
    if (_dismissing) return;
    final absVelocity = velocity.abs();
    final height = _viewportHeight();
    if (absVelocity > _CompactWideOverlaySheet._flingThreshold) {
      final v = (absVelocity / height).clamp(1.0, 6.0);
      if (velocity > 0) {
        // Fling downward — dismiss.
        _startDismiss(flingVelocity: v);
      } else {
        // Fling upward — snap open.
        _controller.fling(velocity: v);
      }
    } else {
      // Low velocity — snap to nearest edge.
      if (_controller.value < _CompactWideOverlaySheet._snapDismissThreshold) {
        _startDismiss();
      } else {
        unawaited(
          _controller.animateTo(
            1,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    }
  }

  void _startDismiss({double? flingVelocity}) {
    if (_dismissing) return;
    _dismissing = true;
    // Always use a physics fling so the dismiss animation matches the
    // finger-driven swipe feel regardless of how it was triggered
    // (gesture, back button, or programmatic close).
    final v = flingVelocity ?? 3.0;
    _controller.fling(velocity: -v);
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (_dismissing) return false;
    if (notification is OverscrollNotification && notification.overscroll < 0) {
      _applyDragDelta(-notification.overscroll);
      return false;
    }
    if (notification is ScrollUpdateNotification &&
        notification.metrics.pixels >
            notification.metrics.minScrollExtent + 0.5 &&
        _controller.value < 0.995) {
      // Scrolling down into content — snap back to fully open.
      unawaited(
        _controller.animateTo(
          1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        ),
      );
      return false;
    }
    if (notification is ScrollEndNotification) {
      // Use the gesture's final velocity so a fast downward fling on the
      // list (when already at the top) triggers a dismiss even though the
      // position-based threshold hasn't been crossed.
      final velocity = notification.dragDetails?.primaryVelocity ?? 0;
      _settleAfterDrag(velocity: velocity);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        // Fade in quickly (complete by 50% of the slide) then stay fully
        // opaque, and fade out symmetrically when dragging back down.
        final opacity = Curves.easeOut.transform(
          (progress / 0.5).clamp(0.0, 1.0),
        );
        return Opacity(
          opacity: opacity,
          child: FractionalTranslation(
            translation: Offset(0, 1.0 - progress),
            child: child,
          ),
        );
      },
      child: Material(
        color: cs.surface,
        child: SafeArea(
          top: true,
          bottom: false,
          // The GestureDetector wraps the ENTIRE panel so dismissal drags
          // can start from any non-scrollable region (pill, title bar, or
          // the queue header row).  The inner scrollable wins the gesture
          // arena for normal scroll gestures; this detector takes over when
          // the list is at its top boundary or the drag is on a
          // non-scrollable area.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) {}, // no-op; reserved for future use
            onVerticalDragUpdate: (details) {
              final delta = details.primaryDelta;
              if (delta == null) return;
              _applyDragDelta(delta);
            },
            onVerticalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              _settleAfterDrag(velocity: velocity);
            },
            onVerticalDragCancel: () => _settleAfterDrag(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // ── Drag pill + optional title bar ─────────────────────────
                const SizedBox(height: 8),
                // Drag pill indicator.
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                if (widget.showTopBar) ...<Widget>[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 12, 8),
                    child: Row(
                      children: <Widget>[
                        IconButton(
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          onPressed: () => _startDismiss(),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        Expanded(
                          child: Text(
                            widget.title,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                ] else
                  const SizedBox(height: 4),
                // ── Scrollable content area ─────────────────────────────────
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleScrollNotification,
                    child: widget.child,
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

class _NowPlayingSettingsPanel extends ConsumerWidget {
  const _NowPlayingSettingsPanel({
    required this.song,
    this.onCollapse,
    this.fullscreenLyricsSongId,
    this.fullscreenLyricsTitle,
    this.onOpenFullscreenLyrics,
  });

  final SongsTableData? song;
  final VoidCallback? onCollapse;
  final String? fullscreenLyricsSongId;
  final String? fullscreenLyricsTitle;
  final VoidCallback? onOpenFullscreenLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final playbackSpeed =
        ref.watch(appSettingsProvider).asData?.value.playbackSpeed ?? 1;
    final currentSongRating = song == null
        ? null
        : ref.watch(songRatingProvider(song!.id)).asData?.value;
    final isRemote = song != null && !isServerAddressableSongId(song!.id);
    final songDownloadState = song == null
        ? SongDownloadState.none
        : ref.watch(songDownloadStateProvider(song!.id));
    final disabledColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.38);

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      children: <Widget>[
        ListTile(
          leading: const Icon(Icons.speed),
          title: Text(l10n.playbackSettingsPlaybackSpeedLabel),
          subtitle: Text(formatPlaybackSpeed(playbackSpeed)),
          onTap: () => _showPlaybackSpeedSheet(context, ref, playbackSpeed),
        ),
        if (song != null)
          ListTile(
            iconColor: isRemote ? disabledColor : null,
            textColor: isRemote ? disabledColor : null,
            leading: const Icon(Icons.star_outline),
            title: Text(l10n.ratingTitle),
            subtitle: Text(l10n.ratingHint),
            trailing: isRemote
                ? IgnorePointer(
                    child: Opacity(
                      opacity: 0.38,
                      child: RatingWidget(
                        rating: currentSongRating,
                        compact: true,
                        onChanged: (_) {},
                      ),
                    ),
                  )
                : RatingWidget(
                    rating: currentSongRating,
                    compact: true,
                    onChanged: (next) {
                      unawaited(
                        setSongRating(song!.id, next, ref).catchError((_) {
                          if (context.mounted) {
                            AppNoticeMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(l10n.ratingUpdateFailed)),
                            );
                          }
                        }),
                      );
                    },
                  ),
            onTap: isRemote
                ? () => AppNoticeMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.remoteSourceActionUnavailable)),
                  )
                : null,
          ),
        if (fullscreenLyricsSongId != null &&
            fullscreenLyricsTitle != null &&
            onOpenFullscreenLyrics != null)
          ListTile(
            leading: const Icon(Icons.fullscreen),
            title: Text(l10n.nowPlayingLyrics),
            onTap: onOpenFullscreenLyrics,
          ),
        if (song?.albumId != null && song!.albumId!.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.album_outlined),
            title: Text(l10n.nowPlayingGoToAlbum),
            onTap: () {
              onCollapse?.call();
              NavService.goToAlbum(context, ref, song!.albumId!);
            },
          ),
        if (song?.artistId != null && song!.artistId!.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(l10n.nowPlayingGoToArtist),
            onTap: () {
              onCollapse?.call();
              NavService.goToArtist(context, ref, song!.artistId!);
            },
          ),
        if (song != null)
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: Text(l10n.librarySongMenuAddToPlaylist),
            onTap: () => showAddToPlaylistSheet(context, ref, [song!.id]),
          ),
        if (song != null &&
            songDownloadState.status == SongDownloadStatus.downloaded)
          ListTile(
            leading: Icon(
              Icons.delete_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              l10n.deleteDownloadAction,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            onTap: () => unawaited(
              confirmAndDeleteDownload(context, ref, song!.id),
            ),
          )
        else if (song != null &&
            songDownloadState.status != SongDownloadStatus.queued &&
            songDownloadState.status != SongDownloadStatus.downloading)
          ListTile(
            iconColor: isRemote ? disabledColor : null,
            textColor: isRemote ? disabledColor : null,
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.downloadAction),
            onTap: () async {
              if (isRemote) {
                AppNoticeMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.remoteSourceActionUnavailable)),
                );
                return;
              }
              final choice = await showDownloadQualitySheet(context);
              if (choice == null || !context.mounted) return;
              final service = ref.read(downloadServiceProvider);
              await service.enqueueSong(
                song!.id,
                quality: choice.quality,
                format: choice.format,
              );
              if (context.mounted) {
                AppNoticeMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.downloadSongQueued)),
                );
              }
            },
          ),
      ],
    );
  }
}

class _EmbeddedMixPanel extends ConsumerWidget {
  const _EmbeddedMixPanel({required this.seedSongId});

  final String seedSongId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final instantMix = ref.watch(instantMixProvider);
    final sameVibes = ref.watch(sameVibesProvider);
    final preferredMixMode = ref.watch(preferredMixModeProvider);
    final useLegacy = preferredMixMode == PreferredMixMode.legacyInstantMix;
    final active = useLegacy ? instantMix.active : sameVibes.active;
    final loading = useLegacy
        ? (instantMix.refilling && instantMix.active)
        : (sameVibes.refilling && sameVibes.active);
    final title = useLegacy
        ? l10n.nowPlayingInstantMixLabel
        : l10n.nowPlayingSameVibesLabel;
    final subtitle = useLegacy
        ? l10n.nowPlayingInstantMixDescription
        : l10n.nowPlayingSameVibesDescription;
    final isRemote = !isServerAddressableSongId(seedSongId);
    final legacyMixUnavailable = isRemote && useLegacy;
    final disabledColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.38);
    final cards = <Widget>[
      Card(
        child: ListTile(
          iconColor: legacyMixUnavailable ? disabledColor : null,
          textColor: legacyMixUnavailable ? disabledColor : null,
          leading: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.explore_outlined),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: active ? const Icon(Icons.check_circle) : null,
          onTap: legacyMixUnavailable
              ? () => AppNoticeMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.remoteSourceInstantMixUnavailable),
                  ),
                )
              : () async {
                  await togglePreferredMixMode(ref, seedSongId: seedSongId);
                },
        ),
      ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      children: cards,
    );
  }
}
