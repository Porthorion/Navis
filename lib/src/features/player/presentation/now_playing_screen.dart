import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/player/presentation/smart_queue_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/common_widgets/rating_widget.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/domain/set_rating.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/smart_queue_state.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/utils/format_utils.dart';

String _formatDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({
    super.key,
    this.onCollapse,
    this.onShowQueue,
    this.wideEmbeddedMode = false,
  });

  final VoidCallback? onCollapse;
  final VoidCallback? onShowQueue;
  final bool wideEmbeddedMode;

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  /// Dominant color extracted from the current cover art for tinting.
  Color? _artTintColor;

  /// The cover art ID that [_artTintColor] was extracted from.
  String? _extractedCoverArtId;

  Future<void> _extractArtColor(String? coverArtId) async {
    if (coverArtId == _extractedCoverArtId) return;
    _extractedCoverArtId = coverArtId;

    if (coverArtId == null || coverArtId.trim().isEmpty) {
      if (mounted) setState(() => _artTintColor = null);
      return;
    }

    final api = ref.read(subsonicApiProvider);
    if (api == null) {
      if (mounted) setState(() => _artTintColor = null);
      return;
    }

    final url = api.getCoverArtUrl(id: coverArtId, size: 64).toString();
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: NetworkImage(url),
        brightness: Theme.of(context).brightness,
      );
      if (mounted) setState(() => _artTintColor = scheme.primary);
    } on Exception {
      if (mounted) setState(() => _artTintColor = null);
    }
  }

  Future<void> _extractArtColorFromUrl(String? artUrl) async {
    if (artUrl == _extractedCoverArtId) return;
    _extractedCoverArtId = artUrl;

    if (artUrl == null || artUrl.trim().isEmpty) {
      if (mounted) setState(() => _artTintColor = null);
      return;
    }

    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: NetworkImage(artUrl),
        brightness: Theme.of(context).brightness,
      );
      if (mounted) setState(() => _artTintColor = scheme.primary);
    } on Exception {
      if (mounted) setState(() => _artTintColor = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktopUiV1 = ref.watch(desktopUiV1EnabledProvider);
    final effectiveWideMode =
        widget.wideEmbeddedMode || (desktopUiV1 && isDesktopRuntime);
    final playback = ref.watch(playerStateProvider);
    final currentSongId = playback.currentSongId;
    final songAsync = currentSongId == null
        ? const AsyncValue<SongsTableData?>.data(null)
        : ref.watch(songByIdProvider(currentSongId));
    final song = songAsync.asData?.value;
    final currentMediaItem = ref.watch(currentMediaItemProvider).asData?.value;
    final artTinted = ref.watch(artTintedNowPlayingProvider);

    // Trigger color extraction when art-tinted mode is on.
    if (artTinted) {
      // Schedule after build to avoid setState during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (playback.isRadioMode) {
          _extractArtColorFromUrl(playback.radioStation?.nowPlayingArtUrl);
        } else {
          final coverArtId = song?.coverArt;
          if (coverArtId != null && coverArtId.trim().isNotEmpty) {
            _extractArtColor(coverArtId);
          } else {
            _extractArtColorFromUrl(currentMediaItem?.artUri?.toString());
          }
        }
      });
    } else if (!artTinted && _artTintColor != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _artTintColor = null);
      });
    }

    final surfaceColor = Theme.of(context).colorScheme.surface;
    final tintColor = artTinted ? _artTintColor : null;
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
        : math.max(
            androidBottomInsetFloor,
            inheritedBottomInset,
          );
    final resolvedBottomSafeInset = effectiveWideMode
        ? 0.0
        : math.max(
            bottomSafeInset,
            math.max(
              mediaQuery.systemGestureInsets.bottom,
              rawViewPaddingBottom,
            ),
          );

    return Material(
      color: surfaceColor,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
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
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.only(bottom: resolvedBottomSafeInset),
            child: effectiveWideMode
                ? Column(
                    children: <Widget>[
                      Expanded(
                        child: _NowPlayingBody(
                          playback: playback,
                          song: playback.isRadioMode ? null : song,
                          wideEmbeddedMode: effectiveWideMode,
                          onCollapse: widget.onCollapse,
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: <Widget>[
                      const _NowPlayingHandle(),
                      Expanded(
                        child: _NowPlayingBody(
                          playback: playback,
                          song: playback.isRadioMode ? null : song,
                          wideEmbeddedMode: effectiveWideMode,
                          onCollapse: widget.onCollapse,
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
      builder: (context, sheetRef, _) {
        final currentSongRating = song == null
            ? null
            : sheetRef.watch(songRatingProvider(song.id)).asData?.value;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
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
                    leading: const Icon(Icons.star_outline),
                    title: Text(l10n.ratingTitle),
                    subtitle: Text(l10n.ratingHint),
                    trailing: RatingWidget(
                      rating: currentSongRating,
                      compact: true,
                      onChanged: (next) {
                        unawaited(
                          setSongRating(song.id, next, sheetRef).catchError((
                            _,
                          ) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(l10n.ratingUpdateFailed),
                                ),
                              );
                            }
                          }),
                        );
                      },
                    ),
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
                if (song != null)
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: Text(l10n.downloadAction),
                    onTap: () async {
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
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l10n.downloadSongQueued)),
                        );
                      }
                    },
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
  return Navigator.of(context).push(
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
    this.onCollapse,
  });

  final PlaybackSnapshot playback;
  final SongsTableData? song;
  final bool wideEmbeddedMode;
  final VoidCallback? onCollapse;

  @override
  ConsumerState<_NowPlayingBody> createState() => _NowPlayingBodyState();
}

class _NowPlayingBodyState extends ConsumerState<_NowPlayingBody> {
  _WideNowPlayingPanel _widePanel = _WideNowPlayingPanel.none;
  bool _showLyrics = false;
  bool _showWideFullscreenLyrics = false;
  final ScrollController _embeddedQueueScrollController = ScrollController();

  @override
  void dispose() {
    _embeddedQueueScrollController.dispose();
    super.dispose();
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
    if (contentWidth < 860 || contentHeight < 460) {
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

  void _togglePlayPause() {
    final handler = ref.read(audioHandlerProvider);
    if (handler == null) return;
    if (widget.playback.playing) {
      unawaited(handler.pause());
    } else {
      unawaited(handler.play());
    }
  }

  void _handleHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 300) return;
    final handler = ref.read(audioHandlerProvider);
    if (handler == null) return;
    HapticFeedback.mediumImpact();
    if (velocity < 0) {
      // Swipe left → next track
      unawaited(handler.skipToNext());
    } else {
      // Swipe right → previous track
      unawaited(handler.skipToPrevious());
    }
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
      setState(() {
        _showWideFullscreenLyrics = false;
        _widePanel = _WideNowPlayingPanel.queue;
      });
      return;
    }
    if (velocity > 320) {
      if (_widePanel != _WideNowPlayingPanel.none) {
        setState(() => _widePanel = _WideNowPlayingPanel.none);
        return;
      }
      if (_showWideFullscreenLyrics) {
        setState(() => _showWideFullscreenLyrics = false);
        return;
      }
      widget.onCollapse?.call();
    }
  }

  Future<void> _openLyricsFullscreen(
    BuildContext context,
    String songId,
    String title,
  ) async {
    if (widget.wideEmbeddedMode) {
      setState(() {
        _showLyrics = false;
        _widePanel = _WideNowPlayingPanel.none;
        _showWideFullscreenLyrics = true;
      });
      return;
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutMode = _resolveLayoutMode(constraints.maxWidth);
        final splitMetrics = layoutMode == _NowPlayingLayoutMode.split
            ? _resolveSplitMetrics(constraints)
            : null;
        final isSplitNowPlaying = splitMetrics != null;
        final supportsSplitPanelOverlay =
            widget.wideEmbeddedMode && isSplitNowPlaying;

        if (widget.wideEmbeddedMode &&
            !isSplitNowPlaying &&
            _showWideFullscreenLyrics &&
            playback.currentSongId != null) {
          return _EmbeddedNowPlayingPanelScaffold(
            key: const ValueKey<String>('wide-fullscreen-lyrics'),
            title: l10n.nowPlayingLyrics,
            subtitle: title,
            onBack: () => setState(() => _showWideFullscreenLyrics = false),
            child: _InlineLyrics(songId: playback.currentSongId!),
          );
        }
        if (widget.wideEmbeddedMode &&
            !isSplitNowPlaying &&
            _showWideFullscreenLyrics &&
            playback.currentSongId == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _showWideFullscreenLyrics = false);
            }
          });
        }

        if (!supportsSplitPanelOverlay &&
            _widePanel != _WideNowPlayingPanel.none) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _widePanel = _WideNowPlayingPanel.none);
            }
          });
        }

        final tightHeight = constraints.maxHeight < 640;
        final compactHeight = constraints.maxHeight < 760;
        final compactTransport =
            compactHeight || layoutMode == _NowPlayingLayoutMode.compact;
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
        final artOrLyrics = isRadio
            ? _RadioCoverArt(
                artUrl: radioMeta?.nowPlayingArtUrl,
                maxSize: artMaxSize,
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: showInlineLyrics
                    ? _InlineLyrics(
                        songId: playback.currentSongId!,
                        maxSize: artMaxSize,
                      )
                    : GestureDetector(
                        key: const ValueKey('cover'),
                        onTap: _togglePlayPause,
                        onHorizontalDragEnd: _handleHorizontalSwipe,
                        child: hasCoverArtId
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
          _TrackInfo(
            title: title,
            artist: artist,
            album: album,
            compact: compactSpacing,
            onTitleTap: isRadio
                ? (radioMeta?.nowPlayingTitle != null &&
                          radioMeta!.nowPlayingTitle!.isNotEmpty
                      ? () => NavService.goToSearch(
                          context,
                          ref,
                          radioMeta.nowPlayingTitle!,
                        )
                      : null)
                : null,
            onArtistTap: isRadio
                ? (radioMeta?.nowPlayingArtist != null &&
                          radioMeta!.nowPlayingArtist!.isNotEmpty
                      ? () => NavService.goToSearch(
                          context,
                          ref,
                          radioMeta.nowPlayingArtist!,
                        )
                      : null)
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
          if (!isRadio) ...[
            SizedBox(
              height: isSplitNowPlaying ? (compactHeight ? 8 : 10) : 12,
            ),
            _NowPlayingInfoPanel(
              song: song,
              album: albumDetails,
              playback: playback,
              currentMediaItem: currentMediaItem,
              playbackSpeed: playbackSpeed,
            ),
          ],
          SizedBox(
            height: isSplitNowPlaying ? (compactHeight ? 6 : 10) : 16,
          ),
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
            ),
            SizedBox(height: compactSpacing ? 4 : 8),
            if (!isRadio)
              _ActionRow(
                song: song,
                songId: playback.currentSongId,
                isLiked: playback.isCurrentSongLiked,
                showLyrics: widget.wideEmbeddedMode
                    ? _showWideFullscreenLyrics
                    : _showLyrics,
                onOpenSettingsSheet: !supportsSplitPanelOverlay
                    ? () => _showNowPlayingSettingsSheet(
                        context,
                        ref,
                        song,
                        fullscreenLyricsSongId:
                            !widget.wideEmbeddedMode &&
                                !fullscreenLyricsMode &&
                                playback.currentSongId != null
                            ? playback.currentSongId
                            : null,
                        fullscreenLyricsTitle:
                            !widget.wideEmbeddedMode &&
                                !fullscreenLyricsMode &&
                                playback.currentSongId != null
                            ? title
                            : null,
                      )
                    : null,
                onLyricsToggle: playback.currentSongId == null
                    ? null
                    : () {
                        if (widget.wideEmbeddedMode) {
                          setState(() {
                            _widePanel = _WideNowPlayingPanel.none;
                            _showLyrics = false;
                            _showWideFullscreenLyrics =
                                !_showWideFullscreenLyrics;
                          });
                          return;
                        }
                        if (fullscreenLyricsMode) {
                          _openLyricsFullscreen(
                            context,
                            playback.currentSongId!,
                            title,
                          );
                          return;
                        }
                        setState(() => _showLyrics = !_showLyrics);
                      },
                wideEmbeddedMode: supportsSplitPanelOverlay,
                onOpenQueuePanel: supportsSplitPanelOverlay
                    ? () => setState(
                        () {
                          _showWideFullscreenLyrics = false;
                          _widePanel = _WideNowPlayingPanel.queue;
                        },
                      )
                    : null,
                onOpenSettingsPanel: supportsSplitPanelOverlay
                    ? () => setState(
                        () {
                          _showWideFullscreenLyrics = false;
                          _widePanel = _WideNowPlayingPanel.settings;
                        },
                      )
                    : null,
                onOpenMixPanel: supportsSplitPanelOverlay
                    ? () => setState(() {
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
            .min(
              rightPaneWidth - 56,
              constraints.maxHeight * 0.36,
            )
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
          child: _NowPlayingInfoGrid(
            song: song,
            album: albumDetails,
            playback: playback,
            currentMediaItem: currentMediaItem,
            playbackSpeed: playbackSpeed,
          ),
        );
        final splitCoverArt = isRadio
            ? _RadioCoverArt(
                artUrl: radioMeta?.nowPlayingArtUrl,
                maxSize: splitCoverArtMaxSize,
              )
            : GestureDetector(
                onTap: _togglePlayPause,
                onHorizontalDragEnd: _handleHorizontalSwipe,
                child: hasCoverArtId
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
              );
        final splitBottomStack = Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Center(child: splitCoverArt),
            const SizedBox(height: 12),
            _TrackInfo(
              title: title,
              artist: artist,
              album: album,
              compact: true,
              onTitleTap: isRadio
                  ? (radioMeta?.nowPlayingTitle != null &&
                            radioMeta!.nowPlayingTitle!.isNotEmpty
                        ? () => NavService.goToSearch(
                            context,
                            ref,
                            radioMeta.nowPlayingTitle!,
                          )
                        : null)
                  : null,
              onArtistTap: isRadio
                  ? (radioMeta?.nowPlayingArtist != null &&
                            radioMeta!.nowPlayingArtist!.isNotEmpty
                        ? () => NavService.goToSearch(
                            context,
                            ref,
                            radioMeta.nowPlayingArtist!,
                          )
                        : null)
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
            if (!isRadio) ...<Widget>[
              const SizedBox(height: 12),
              _SeekBar(playback: playback),
              const SizedBox(height: 8),
            ],
            _TransportControls(
              playback: playback,
              isRadio: isRadio,
              compact: compactTransport,
            ),
            const SizedBox(height: 8),
            if (!isRadio)
              _ActionRow(
                song: song,
                songId: playback.currentSongId,
                isLiked: playback.isCurrentSongLiked,
                showLyrics: true,
                onOpenSettingsSheet: !supportsSplitPanelOverlay
                    ? () => _showNowPlayingSettingsSheet(
                        context,
                        ref,
                        song,
                        fullscreenLyricsSongId: null,
                        fullscreenLyricsTitle: null,
                      )
                    : null,
                onLyricsToggle: playback.currentSongId == null ? null : () {},
                wideEmbeddedMode: supportsSplitPanelOverlay,
                onOpenQueuePanel: supportsSplitPanelOverlay
                    ? () => setState(
                        () {
                          _showWideFullscreenLyrics = false;
                          _widePanel = _WideNowPlayingPanel.queue;
                        },
                      )
                    : null,
                onOpenSettingsPanel: supportsSplitPanelOverlay
                    ? () => setState(
                        () {
                          _showWideFullscreenLyrics = false;
                          _widePanel = _WideNowPlayingPanel.settings;
                        },
                      )
                    : null,
                onOpenMixPanel: supportsSplitPanelOverlay
                    ? () => setState(() {
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
                onClose: () =>
                    setState(() => _widePanel = _WideNowPlayingPanel.none),
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
                onClose: () =>
                    setState(() => _widePanel = _WideNowPlayingPanel.none),
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
              SizedBox(
                width: metrics.leftPaneWidth,
                child: lyricsPane,
              ),
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
            onVerticalDragEnd: (details) =>
                _handleWideVerticalSwipe(details, splitLayout: true),
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
        size: 640,
        width: artSize,
        height: artSize,
        borderRadius: npRadius,
        placeholderIcon: Icons.music_note_outlined,
        semanticLabel: semanticLabel,
      );
    }

    final mq = MediaQuery.of(context).size;
    final widthBased = mq.width - 48;
    final heightBased = mq.height * 0.52;
    final baseSize = (widthBased < heightBased ? widthBased : heightBased);
    final artSize = baseSize.clamp(180.0, 600.0);

    return CoverArtImage(
      coverArtId: coverArtId,
      size: 640,
      width: artSize,
      height: artSize,
      borderRadius: npRadius,
      placeholderIcon: Icons.music_note_outlined,
      semanticLabel: semanticLabel,
    );
  }
}

class _RadioCoverArt extends ConsumerWidget {
  const _RadioCoverArt({this.artUrl, this.maxSize});

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
    required this.title,
    required this.artist,
    required this.album,
    this.compact = false,
    this.onTitleTap,
    this.onArtistTap,
    this.onAlbumTap,
  });

  final String title;
  final String artist;
  final String album;
  final bool compact;
  final VoidCallback? onTitleTap;
  final VoidCallback? onArtistTap;
  final VoidCallback? onAlbumTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTitleTap,
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              fontSize: compact ? 20 : null,
              color: onTitleTap != null
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
        SizedBox(height: compact ? 2 : 4),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onArtistTap,
          child: Text(
            artist,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontSize: compact ? 15 : null,
              color: onArtistTap != null
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
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
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: compact ? 13 : null,
              color: onAlbumTap != null
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
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
                                        ScaffoldMessenger.of(
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
                                  style:
                                      Theme.of(
                                        context,
                                      ).textTheme.bodySmall?.copyWith(
                                        color: colors.onSurfaceVariant
                                            .withValues(
                                              alpha: 0.82,
                                            ),
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
      value: _formatAudioQuality(
        song: song,
        mediaItem: currentMediaItem,
      ),
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
              Text(
                ratingPage.semanticLabel,
                style: labelStyle,
              ),
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
                        ScaffoldMessenger.of(context).showSnackBar(
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

String _formatQueuePosition(
  AppLocalizations l10n,
  PlaybackSnapshot playback,
) {
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
  });

  final PlaybackSnapshot playback;
  final bool isRadio;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPlaying = playback.playing;

    if (isRadio) {
      // Simplified radio transport: just play/pause and stop.
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
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
            HapticFeedback.mediumImpact();
            final handler = ref.read(audioHandlerProvider);
            unawaited(handler?.skipToPrevious());
          },
        ),
        SizedBox(width: compact ? 4 : 8),
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
        ),
        SizedBox(width: compact ? 4 : 8),
        IconButton(
          icon: Icon(Icons.skip_next, size: compact ? 28 : 32),
          visualDensity: compact ? VisualDensity.compact : null,
          tooltip: l10n.nowPlayingNext,
          onPressed: () {
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
      ],
    );
  }
}

class _InlineLyrics extends ConsumerWidget {
  const _InlineLyrics({
    required this.songId,
    this.maxSize,
  });

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
      return SizedBox(
        width: framedSize,
        height: framedSize,
        child: child,
      );
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
  const _FullscreenLyricsPage({
    required this.songId,
    required this.title,
  });

  final String songId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final playback = ref.watch(playerStateProvider);
    final mediaSize = MediaQuery.sizeOf(context);
    final showMediaControls = mediaSize.height > mediaSize.width;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
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
              if (showMediaControls) ...<Widget>[
                const SizedBox(height: 8),
                if (!playback.isRadioMode) _SeekBar(playback: playback),
                const SizedBox(height: 6),
                _TransportControls(
                  playback: playback,
                  isRadio: playback.isRadioMode,
                ),
              ],
            ],
          ),
        ),
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
    final smartQueue = ref.watch(smartQueueProvider);
    final smartQueueAvailable =
        ref.watch(smartQueueAvailableProvider).asData?.value ?? false;
    final mixActive = instantMix.active || smartQueue.active;
    final mixLoading = instantMix.refilling || smartQueue.refilling;
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
            smartQueue.active && smartQueue.profile != null
                ? smartQueue.profile!.icon
                : (instantMix.active
                      ? Icons.explore
                      : (smartQueueAvailable
                            ? Icons.auto_awesome_outlined
                            : Icons.explore_outlined)),
            color: mixActive
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
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
          onTap: widget.songId == null
              ? null
              : () {
                  if (widget.wideEmbeddedMode &&
                      widget.onOpenMixPanel != null) {
                    widget.onOpenMixPanel!.call();
                    return;
                  }
                  if (smartQueueAvailable) {
                    showMixModeSheet(context, seedSongId: widget.songId!);
                  } else {
                    ref.read(instantMixProvider.notifier).toggle(widget.songId);
                  }
                },
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
          onTap: widget.songId == null
              ? null
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
      ],
    );
  }
}

class _NowPlayingActionButton extends StatelessWidget {
  const _NowPlayingActionButton({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.42 : 1,
      child: IconButton(
        tooltip: label,
        onPressed: onTap,
        icon: icon,
      ),
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
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.26),
            ),
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
                                        .withValues(
                                          alpha: 0.4,
                                        ),
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

class _EmbeddedNowPlayingPanelScaffold extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(title, style: theme.textTheme.titleMedium),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
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
        Expanded(child: child),
      ],
    );
  }
}

class _NowPlayingSettingsPanel extends ConsumerWidget {
  const _NowPlayingSettingsPanel({
    required this.song,
    this.onCollapse,
  });

  final SongsTableData? song;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final playbackSpeed =
        ref.watch(appSettingsProvider).asData?.value.playbackSpeed ?? 1;
    final currentSongRating = song == null
        ? null
        : ref.watch(songRatingProvider(song!.id)).asData?.value;

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
            leading: const Icon(Icons.star_outline),
            title: Text(l10n.ratingTitle),
            subtitle: Text(l10n.ratingHint),
            trailing: RatingWidget(
              rating: currentSongRating,
              compact: true,
              onChanged: (next) {
                unawaited(
                  setSongRating(song!.id, next, ref).catchError((_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.ratingUpdateFailed)),
                      );
                    }
                  }),
                );
              },
            ),
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
        if (song != null)
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.downloadAction),
            onTap: () async {
              final choice = await showDownloadQualitySheet(context);
              if (choice == null || !context.mounted) return;
              final service = ref.read(downloadServiceProvider);
              await service.enqueueSong(
                song!.id,
                quality: choice.quality,
                format: choice.format,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
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
    final smartQueue = ref.watch(smartQueueProvider);
    final instantMix = ref.watch(instantMixProvider);
    final cards = <Widget>[
      for (final profile in SmartQueueProfile.values)
        Card(
          child: ListTile(
            leading: Icon(profile.icon, color: profile.color),
            title: Text(_embeddedSmartQueueProfileTitle(l10n, profile)),
            subtitle: Text(
              _embeddedSmartQueueProfileDescription(l10n, profile),
            ),
            trailing: smartQueue.active && smartQueue.profile == profile
                ? const Icon(Icons.check_circle)
                : null,
            onTap: () async {
              ref.read(instantMixProvider.notifier).deactivate();
              if (smartQueue.active && smartQueue.profile == profile) {
                ref.read(smartQueueProvider.notifier).deactivate();
                return;
              }
              ref.read(smartQueueProvider.notifier).deactivate();
              await ref
                  .read(smartQueueProvider.notifier)
                  .activate(profile, seedSongId);
            },
          ),
        ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.explore_outlined),
          title: Text(l10n.nowPlayingInstantMixLabel),
          subtitle: Text(l10n.nowPlayingInstantMixDescription),
          trailing: instantMix.active ? const Icon(Icons.check_circle) : null,
          onTap: () async {
            ref.read(smartQueueProvider.notifier).deactivate();
            if (instantMix.active) {
              ref.read(instantMixProvider.notifier).deactivate();
              return;
            }
            await ref.read(instantMixProvider.notifier).activate(seedSongId);
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

String _embeddedSmartQueueProfileTitle(
  AppLocalizations l10n,
  SmartQueueProfile profile,
) {
  switch (profile) {
    case SmartQueueProfile.steadyVibes:
      return l10n.smartQueueSteadyVibes;
    case SmartQueueProfile.discoveryMix:
      return l10n.smartQueueDiscoveryMix;
    case SmartQueueProfile.deepDive:
      return l10n.smartQueueDeepDive;
    case SmartQueueProfile.energyFlow:
      return l10n.smartQueueEnergyFlow;
  }
}

String _embeddedSmartQueueProfileDescription(
  AppLocalizations l10n,
  SmartQueueProfile profile,
) {
  switch (profile) {
    case SmartQueueProfile.steadyVibes:
      return l10n.smartQueueSteadyVibesDesc;
    case SmartQueueProfile.discoveryMix:
      return l10n.smartQueueDiscoveryMixDesc;
    case SmartQueueProfile.deepDive:
      return l10n.smartQueueDeepDiveDesc;
    case SmartQueueProfile.energyFlow:
      return l10n.smartQueueEnergyFlowDesc;
  }
}
