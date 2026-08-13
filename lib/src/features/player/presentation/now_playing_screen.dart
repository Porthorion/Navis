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
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/features/player/presentation/desktop_volume_slider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/presentation/normal_playback_metadata_navigation.dart';
import 'package:navis/src/features/player/presentation/playback_seek_bar_style.dart';
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
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/artist_utils.dart';
import 'package:navis/src/utils/format_utils.dart';

part 'now_playing_speed_sheet.dart';
part 'now_playing_seek_bar.dart';
part 'now_playing_metadata_panel.dart';
part 'now_playing_transport_controls.dart';
part 'now_playing_lyrics.dart';
part 'now_playing_actions.dart';
part 'now_playing_wide_panels.dart';

/// A single artist entry for [_TrackInfo.artistLinks].
typedef _ArtistLink = ({String name, VoidCallback? onTap});

enum _TrackNavigationFeedback { replayCurrent, noNext }

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
  final cacheManager = ref.read(coverArtCacheManagerProvider);
  final trimmedCoverArtId = coverArtId?.trim() ?? '';
  if (trimmedCoverArtId.isNotEmpty) {
    final api = ref.read(subsonicApiProvider);
    if (api == null) {
      return null;
    }
    final coverUrl = api.getCoverArtUrl(id: trimmedCoverArtId, size: 768);
    return CachedNetworkImageProvider(
      coverUrl.toString(),
      cacheManager: cacheManager,
      cacheKey: coverArtImageCacheKey(trimmedCoverArtId, 768),
    );
  }

  final trimmedArtUrl = artUrl?.trim() ?? '';
  if (trimmedArtUrl.isEmpty) {
    return null;
  }
  return CachedNetworkImageProvider(trimmedArtUrl, cacheManager: cacheManager);
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
    final trimmedCoverArtId = coverArtId?.trim() ?? '';
    final coverArtInterest = trimmedCoverArtId.isEmpty
        ? null
        : ref
              .read(coverArtLoadCoordinatorProvider)
              .trackInterest(
                coverArtImageCacheKey(trimmedCoverArtId, 768),
                CoverArtLoadPriority.critical,
              );
    try {
      await precacheImage(imageProvider, context, onError: (_, _) {});
      final scheme = await ColorScheme.fromImageProvider(
        provider: imageProvider,
        brightness: brightness,
      );
      _nowPlayingTintColorCache[cacheKey] = scheme.primary;
    } on Exception {
      // Best-effort warm path: ignore extraction failures.
    } finally {
      coverArtInterest?.dispose();
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
    this.showEmbeddedVolumeBelowActions = false,
    this.onBackInterceptorChanged,
    this.onCompactWideOverlayActiveChanged,
    this.onCompactWideQueueRequestChanged,
  });

  final VoidCallback? onCollapse;
  final VoidCallback? onShowQueue;
  final bool wideEmbeddedMode;
  final bool compactWideLandscapeMode;
  final bool showEmbeddedVolumeBelowActions;
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
              showEmbeddedVolumeBelowActions:
                  widget.showEmbeddedVolumeBelowActions,
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
                            unawaited(
                              sheetRef
                                  .read(playbackVolumeProvider.notifier)
                                  .setVolume(v),
                            );
                          },
                          onChangeEnd: (v) => unawaited(
                            sheetRef
                                .read(playbackVolumeProvider.notifier)
                                .setVolume(v, persistImmediately: true),
                          ),
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
                                    showAppNotice(
                                      context,
                                      message: l10n.ratingUpdateFailed,
                                      level: AppNoticeLevel.error,
                                    );
                                  }
                                }),
                              );
                            },
                          ),
                    onTap: isRemote
                        ? () => showAppNotice(
                            context,
                            message: l10n.remoteSourceActionUnavailable,
                            level: AppNoticeLevel.error,
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
                if (song != null &&
                    ((song.albumId ?? '').trim().isNotEmpty ||
                        (song.albumName ?? '').trim().isNotEmpty))
                  ListTile(
                    leading: const Icon(Icons.album_outlined),
                    title: Text(l10n.nowPlayingGoToAlbum),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(
                        NormalPlaybackMetadataNavigator.goToAlbum(
                          context,
                          ref,
                          song: song,
                        ),
                      );
                    },
                  ),
                if (song != null &&
                    ((song.artistId ?? '').trim().isNotEmpty ||
                        (song.artistName ?? '').trim().isNotEmpty))
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(l10n.nowPlayingGoToArtist),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(
                        NormalPlaybackMetadataNavigator.goToArtist(
                          context,
                          ref,
                          song: song,
                        ),
                      );
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
                        showAppNotice(
                          context,
                          message: l10n.remoteSourceActionUnavailable,
                          level: AppNoticeLevel.error,
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
                        showAppNotice(
                          context,
                          message: l10n.downloadSongQueued,
                          level: AppNoticeLevel.success,
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

class _NowPlayingEmbeddedVolumeControl extends ConsumerWidget {
  const _NowPlayingEmbeddedVolumeControl();

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
        onMuteToggle: () => unawaited(
          ref.read(playbackVolumeProvider.notifier).toggleMute(),
        ),
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

class _NowPlayingBody extends ConsumerStatefulWidget {
  const _NowPlayingBody({
    required this.playback,
    this.song,
    this.wideEmbeddedMode = false,
    this.compactWideLandscapeMode = false,
    this.showEmbeddedVolumeBelowActions = false,
    this.onCollapse,
    this.onBackInterceptorChanged,
    this.onCompactWideOverlayActiveChanged,
    this.onCompactWideQueueRequestChanged,
  });

  final PlaybackSnapshot playback;
  final SongsTableData? song;
  final bool wideEmbeddedMode;
  final bool compactWideLandscapeMode;
  final bool showEmbeddedVolumeBelowActions;
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
  bool _isCompactWidePanelDismissing = false;
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
  _TrackNavigationFeedback? _trackNavigationFeedback;

  bool _dismissInternalOverlaysIfVisible() {
    if (_widePanel != _WideNowPlayingPanel.none) {
      _dismissCompactWidePanel();
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
      return null;
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
      return null;
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
        navisResolvePreviousTrackAction(
              queueLength: playback.queueSongIds.length,
              currentIndex: playback.currentIndex,
              position: _livePlaybackPosition(playback),
            ) ==
            NavisPreviousTrackAction.skipToPrevious,
    };
  }

  Duration _livePlaybackPosition(PlaybackSnapshot playback) {
    return ref.read(audioHandlerProvider)?.snapshot.position ??
        playback.position;
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
      final cacheManager = ref.read(coverArtCacheManagerProvider);
      final ImageProvider<Object> imageProvider = CachedNetworkImageProvider(
        artUrl,
        cacheManager: cacheManager,
        cacheKey: coverArtImageCacheKey(trimmedCoverArt, 768),
      );
      unawaited(precacheImage(imageProvider, context, onError: (_, _) {}));
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
    _TrackNavigationFeedback feedback,
  ) async {
    final edgeTarget = switch (direction) {
      ManualTrackChangeDirection.next => -0.14,
      ManualTrackChangeDirection.previous => 0.14,
    };
    setState(() => _trackNavigationFeedback = feedback);
    try {
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
    } finally {
      if (mounted) {
        setState(() => _trackNavigationFeedback = null);
      }
    }
  }

  Future<void> _triggerManualSkipWithAnimation(
    ManualTrackChangeDirection direction, {
    double? initialSwipe,
  }) async {
    if (_artSwipeAwaitingTrackChange || _artSwipeSettling) {
      return;
    }
    final playback = widget.playback;
    if (direction == ManualTrackChangeDirection.previous) {
      final previousAction = navisResolvePreviousTrackAction(
        queueLength: playback.queueSongIds.length,
        currentIndex: playback.currentIndex,
        position: _livePlaybackPosition(playback),
      );
      if (previousAction == NavisPreviousTrackAction.none) {
        return;
      }
      if (previousAction == NavisPreviousTrackAction.restartCurrent) {
        unawaited(HapticFeedback.selectionClick());
        unawaited(ref.read(audioHandlerProvider)?.skipToPrevious());
        await _animateEdgeSnapback(
          direction,
          _TrackNavigationFeedback.replayCurrent,
        );
        return;
      }
    } else if (!_canManualSkipDirection(playback, direction)) {
      unawaited(HapticFeedback.selectionClick());
      await _animateEdgeSnapback(
        direction,
        _TrackNavigationFeedback.noNext,
      );
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
              final feedback = _trackNavigationFeedback;
              final feedbackProgress = (absSwipe / 0.14).clamp(0.0, 1.0);
              final l10n = AppLocalizations.of(context)!;
              final colorScheme = Theme.of(context).colorScheme;
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
                    if (feedback != null)
                      Align(
                        alignment:
                            feedback == _TrackNavigationFeedback.replayCurrent
                            ? Alignment.centerLeft
                            : Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Opacity(
                            opacity: feedbackProgress,
                            child: Transform.scale(
                              scale: 0.8 + (0.2 * feedbackProgress),
                              child: Semantics(
                                liveRegion: true,
                                label:
                                    feedback ==
                                        _TrackNavigationFeedback.replayCurrent
                                    ? l10n.nowPlayingRestartCurrent
                                    : l10n.nowPlayingNoNextTrack,
                                child: DecoratedBox(
                                  key: ValueKey<String>(
                                    'track-navigation-feedback-${feedback.name}',
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primaryContainer,
                                    shape: BoxShape.circle,
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: colorScheme.shadow.withValues(
                                          alpha: 0.22,
                                        ),
                                        blurRadius: 12,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: SizedBox.square(
                                    dimension: 52,
                                    child: Icon(
                                      feedback ==
                                              _TrackNavigationFeedback
                                                  .replayCurrent
                                          ? Icons.replay_rounded
                                          : Icons.skip_next_rounded,
                                      color: colorScheme.onPrimaryContainer,
                                      size: 30,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
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
      _isCompactWidePanelDismissing = false;
      _widePanel = _WideNowPlayingPanel.queue;
    });
  }

  /// Let the compact sheet finish its reverse transition before removing it
  /// from the tree. Queue's close button used to clear [_widePanel] directly,
  /// which skipped that transition and made dismissal visibly abrupt.
  void _dismissCompactWidePanel() {
    if (_widePanel == _WideNowPlayingPanel.none) {
      return;
    }
    if (widget.compactWideLandscapeMode) {
      if (_isCompactWidePanelDismissing) {
        return;
      }
      _updateWideOverlayState(() {
        _isCompactWidePanelDismissing = true;
      });
      return;
    }
    _updateWideOverlayState(() {
      _widePanel = _WideNowPlayingPanel.none;
    });
  }

  void _dismissWideOverlayOrNowPlaying() {
    if (_widePanel != _WideNowPlayingPanel.none) {
      _dismissCompactWidePanel();
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
    final normalTitle = song?.title ?? currentMediaItem?.title;
    final normalArtistName = song?.artistName ?? currentMediaItem?.artist;
    final normalAlbumName = song?.albumName ?? currentMediaItem?.album;
    final normalTitleTap = !isRadio && (normalTitle ?? '').trim().isNotEmpty
        ? () => unawaited(
            NormalPlaybackMetadataNavigator.goToTitle(
              context,
              ref,
              song: song,
              title: normalTitle,
              artistId: resolvedArtistId,
              artistName: normalArtistName,
              albumName: normalAlbumName,
            ),
          )
        : null;
    final normalArtistTap =
        !isRadio &&
            (resolvedArtistId != null ||
                (normalArtistName ?? '').trim().isNotEmpty)
        ? () => unawaited(
            NormalPlaybackMetadataNavigator.goToArtist(
              context,
              ref,
              song: song,
              artistId: resolvedArtistId,
              artistName: normalArtistName,
            ),
          )
        : null;
    final normalAlbumTap =
        !isRadio &&
            ((song?.albumId ?? '').trim().isNotEmpty ||
                (normalAlbumName ?? '').trim().isNotEmpty)
        ? () => unawaited(
            NormalPlaybackMetadataNavigator.goToAlbum(
              context,
              ref,
              song: song,
              albumName: normalAlbumName,
              artistId: resolvedArtistId,
              artistName: normalArtistName,
            ),
          )
        : null;
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
                      isExternalSource: song?.isExternal ?? false,
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
                            isExternalSource: song?.isExternal ?? false,
                          )),
              previousArt: previousSong == null
                  ? null
                  : _CoverArt(
                      coverArtId: previousSong.coverArt,
                      semanticLabel: previousSong.title.isNotEmpty
                          ? previousSong.title
                          : l10n.nowPlayingUnknownTrack,
                      maxSize: artMaxSize,
                      isExternalSource: previousSong.isExternal,
                    ),
              nextArt: nextSong == null
                  ? null
                  : _CoverArt(
                      coverArtId: nextSong.coverArt,
                      semanticLabel: nextSong.title.isNotEmpty
                          ? nextSong.title
                          : l10n.nowPlayingUnknownTrack,
                      maxSize: artMaxSize,
                      isExternalSource: nextSong.isExternal,
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
                      isExternalSource: !isRadio && (song?.isExternal ?? false),
                      onTitleTap: isRadio
                          ? (radioMeta?.nowPlayingTitle != null &&
                                    radioMeta!.nowPlayingTitle!.isNotEmpty
                                ? () {
                                    NavService.openSearch(
                                      context,
                                      ref,
                                      radioMeta.nowPlayingTitle!,
                                      filter: SearchResultType.songs,
                                    );
                                  }
                                : null)
                          : normalTitleTap,
                      artistLinks: isRadio
                          ? (radioMeta?.nowPlayingArtist != null &&
                                    radioMeta!.nowPlayingArtist!.isNotEmpty
                                ? splitArtistNames(radioMeta.nowPlayingArtist!)
                                      .map(
                                        (name) => (
                                          name: name,
                                          onTap: () {
                                            NavService.openSearch(
                                              context,
                                              ref,
                                              name,
                                              filter: SearchResultType.artists,
                                            );
                                          },
                                        ),
                                      )
                                      .toList()
                                : null)
                          : null,
                      onArtistTap: isRadio ? null : normalArtistTap,
                      onAlbumTap: isRadio ? null : normalAlbumTap,
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
                    compact: true,
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
                  if (widget.showEmbeddedVolumeBelowActions) ...<Widget>[
                    SizedBox(height: vSpacing * 0.35),
                    const _NowPlayingEmbeddedVolumeControl(),
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
              dismissRequested: _isCompactWidePanelDismissing,
              onDismiss: () => _updateWideOverlayState(() {
                _isCompactWidePanelDismissing = false;
                _widePanel = _WideNowPlayingPanel.none;
              }),
              child: QueueSheet(
                scrollController: _embeddedQueueScrollController,
                embeddedMode: true,
                onClose: _dismissCompactWidePanel,
              ),
            );
          } else if (_widePanel == _WideNowPlayingPanel.mix &&
              playback.currentSongId != null) {
            compactOverlayKey = const ValueKey<String>('compact-wide-mix');
            compactOverlayPage = _CompactWideOverlaySheet(
              key: compactOverlayKey,
              title: l10n.nowPlayingInstantMixLabel,
              dismissRequested: _isCompactWidePanelDismissing,
              onDismiss: () => _updateWideOverlayState(() {
                _isCompactWidePanelDismissing = false;
                _widePanel = _WideNowPlayingPanel.none;
              }),
              child: _EmbeddedMixPanel(seedSongId: playback.currentSongId!),
            );
          } else if (_widePanel == _WideNowPlayingPanel.settings) {
            compactOverlayKey = const ValueKey<String>('compact-wide-settings');
            compactOverlayPage = _CompactWideOverlaySheet(
              key: compactOverlayKey,
              title: l10n.settingsTitle,
              dismissRequested: _isCompactWidePanelDismissing,
              onDismiss: () => _updateWideOverlayState(() {
                _isCompactWidePanelDismissing = false;
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
        // Mini Player entry lives in the persistent desktop bar and Desktop
        // Window settings, so embedded Now Playing does not duplicate it.
        const showDesktopMiniPlayerToggle = false;
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
                    isExternalSource: song?.isExternal ?? false,
                  )
                : (hasMediaArtUrl
                      ? _RadioCoverArt(artUrl: mediaArtUrl, maxSize: artMaxSize)
                      : _CoverArt(
                          coverArtId: null,
                          semanticLabel: title,
                          maxSize: artMaxSize,
                          isExternalSource: song?.isExternal ?? false,
                        )),
            previousArt: previousSong == null
                ? null
                : _CoverArt(
                    coverArtId: previousSong.coverArt,
                    semanticLabel: previousSong.title.isNotEmpty
                        ? previousSong.title
                        : l10n.nowPlayingUnknownTrack,
                    maxSize: artMaxSize,
                    isExternalSource: previousSong.isExternal,
                  ),
            nextArt: nextSong == null
                ? null
                : _CoverArt(
                    coverArtId: nextSong.coverArt,
                    semanticLabel: nextSong.title.isNotEmpty
                        ? nextSong.title
                        : l10n.nowPlayingUnknownTrack,
                    maxSize: artMaxSize,
                    isExternalSource: nextSong.isExternal,
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
              isExternalSource: !isRadio && (song?.isExternal ?? false),
              onTitleTap: isRadio
                  ? (radioMeta?.nowPlayingTitle != null &&
                            radioMeta!.nowPlayingTitle!.isNotEmpty
                        ? () {
                            NavService.openSearch(
                              context,
                              ref,
                              radioMeta.nowPlayingTitle!,
                              filter: SearchResultType.songs,
                            );
                          }
                        : null)
                  : normalTitleTap,
              artistLinks: isRadio
                  ? (radioMeta?.nowPlayingArtist != null &&
                            radioMeta!.nowPlayingArtist!.isNotEmpty
                        ? splitArtistNames(radioMeta.nowPlayingArtist!)
                              .map(
                                (name) => (
                                  name: name,
                                  onTap: () {
                                    NavService.openSearch(
                                      context,
                                      ref,
                                      name,
                                      filter: SearchResultType.artists,
                                    );
                                  },
                                ),
                              )
                              .toList()
                        : null)
                  : null,
              onArtistTap: isRadio ? null : normalArtistTap,
              onAlbumTap: isRadio ? null : normalAlbumTap,
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
              showMiniPlayerToggle: showDesktopMiniPlayerToggle,
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
            if (widget.showEmbeddedVolumeBelowActions) ...<Widget>[
              SizedBox(height: compactSpacing ? 2 : 6),
              const _NowPlayingEmbeddedVolumeControl(),
            ],
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
                          isExternalSource: song?.isExternal ?? false,
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
                                isExternalSource: song?.isExternal ?? false,
                              )),
                  previousArt: previousSong == null
                      ? null
                      : _CoverArt(
                          coverArtId: previousSong.coverArt,
                          semanticLabel: previousSong.title.isNotEmpty
                              ? previousSong.title
                              : l10n.nowPlayingUnknownTrack,
                          maxSize: splitCoverArtMaxSize,
                          isExternalSource: previousSong.isExternal,
                        ),
                  nextArt: nextSong == null
                      ? null
                      : _CoverArt(
                          coverArtId: nextSong.coverArt,
                          semanticLabel: nextSong.title.isNotEmpty
                              ? nextSong.title
                              : l10n.nowPlayingUnknownTrack,
                          maxSize: splitCoverArtMaxSize,
                          isExternalSource: nextSong.isExternal,
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
                isExternalSource: !isRadio && (song?.isExternal ?? false),
                onTitleTap: isRadio
                    ? (radioMeta?.nowPlayingTitle != null &&
                              radioMeta!.nowPlayingTitle!.isNotEmpty
                          ? () {
                              NavService.openSearch(
                                context,
                                ref,
                                radioMeta.nowPlayingTitle!,
                                filter: SearchResultType.songs,
                              );
                            }
                          : null)
                    : normalTitleTap,
                artistLinks: isRadio
                    ? (radioMeta?.nowPlayingArtist != null &&
                              radioMeta!.nowPlayingArtist!.isNotEmpty
                          ? splitArtistNames(radioMeta.nowPlayingArtist!)
                                .map(
                                  (name) => (
                                    name: name,
                                    onTap: () {
                                      NavService.openSearch(
                                        context,
                                        ref,
                                        name,
                                        filter: SearchResultType.artists,
                                      );
                                    },
                                  ),
                                )
                                .toList()
                          : null)
                    : null,
                onArtistTap: isRadio ? null : normalArtistTap,
                onAlbumTap: isRadio ? null : normalAlbumTap,
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
              showMiniPlayerToggle: showDesktopMiniPlayerToggle,
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
