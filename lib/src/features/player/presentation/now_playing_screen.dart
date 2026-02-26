import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';

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
  });

  final VoidCallback? onCollapse;

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
    final playback = ref.watch(playerStateProvider);
    final currentSongId = playback.currentSongId;
    final songAsync = currentSongId == null
        ? const AsyncValue<SongsTableData?>.data(null)
        : ref.watch(songByIdProvider(currentSongId));
    final song = songAsync.asData?.value;
    final artTinted = ref.watch(artTintedNowPlayingProvider);

    // Trigger color extraction when art-tinted mode is on.
    if (artTinted) {
      // Schedule after build to avoid setState during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (playback.isRadioMode) {
          _extractArtColorFromUrl(playback.radioStation?.nowPlayingArtUrl);
        } else {
          _extractArtColor(song?.coverArt);
        }
      });
    } else if (!artTinted && _artTintColor != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _artTintColor = null);
      });
    }

    final surfaceColor = Theme.of(context).colorScheme.surface;
    final tintColor = artTinted ? _artTintColor : null;

    return Material(
      color: surfaceColor,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 600),
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxHeight < 100) {
                return const SizedBox.shrink();
              }
              return Column(
                children: <Widget>[
                  _NowPlayingAppBar(
                    song: playback.isRadioMode ? null : song,
                    onCollapse: widget.onCollapse,
                    isRadio: playback.isRadioMode,
                  ),
                  Expanded(
                    child: _NowPlayingBody(
                      playback: playback,
                      song: playback.isRadioMode ? null : song,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NowPlayingAppBar extends ConsumerWidget {
  const _NowPlayingAppBar({this.song, this.onCollapse, this.isRadio = false});

  final SongsTableData? song;
  final VoidCallback? onCollapse;
  final bool isRadio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: onCollapse ?? () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              l10n.nowPlayingTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: l10n.nowPlayingMore,
            onPressed: isRadio
                ? null
                : () => _showOverflowMenu(context, ref, song),
          ),
        ],
      ),
    );
  }

  void _showOverflowMenu(
    BuildContext context,
    WidgetRef ref,
    SongsTableData? song,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
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
            // Smart Queue — shown when AudioMuse NV plugin is detected.
            if (song != null &&
                (ref.watch(smartQueueAvailableProvider).asData?.value ?? false))
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: Text(l10n.smartQueueButton),
                subtitle: Text(l10n.smartQueueSubtitle),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showSmartQueueSheet(
                    context,
                    ref,
                    seedSongId: song.id,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingBody extends ConsumerStatefulWidget {
  const _NowPlayingBody({
    required this.playback,
    this.song,
  });

  final PlaybackSnapshot playback;
  final SongsTableData? song;

  @override
  ConsumerState<_NowPlayingBody> createState() => _NowPlayingBodyState();
}

class _NowPlayingBodyState extends ConsumerState<_NowPlayingBody> {
  bool _showLyrics = false;

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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final song = widget.song;
    final playback = widget.playback;
    final isRadio = playback.isRadioMode;
    final radioMeta = playback.radioStation;

    final title = isRadio
        ? (radioMeta?.nowPlayingTitle ??
              radioMeta?.stationName ??
              l10n.radioTitle)
        : (song?.title ?? l10n.nowPlayingUnknownTrack);
    final artist = isRadio
        ? (radioMeta?.nowPlayingArtist ?? radioMeta?.stationName ?? '')
        : (song?.artistName ?? l10n.nowPlayingUnknownArtist);
    final album = isRadio
        ? l10n.radioLive
        : (song?.albumName ?? l10n.nowPlayingUnknownAlbum);

    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // During the expand/collapse animation the available height can be
          // very small (even <2 px). Rendering the full Column at that size
          // causes a RenderFlex overflow. Skip the layout entirely when there
          // isn't enough room — the content is invisible at that point anyway.
          // The fixed-height children (TrackInfo, SeekBar, TransportControls,
          // ActionRow, spacers) need ~300 px; use 350 as a safe threshold.
          if (constraints.maxHeight < 350) {
            return const SizedBox.shrink();
          }

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: <Widget>[
                const SizedBox(height: 8),
                Expanded(
                  child: Center(
                    child: isRadio
                        ? _RadioCoverArt(artUrl: radioMeta?.nowPlayingArtUrl)
                        : (_showLyrics && playback.currentSongId != null
                              ? _InlineLyrics(
                                  songId: playback.currentSongId!,
                                )
                              : GestureDetector(
                                  onTap: _togglePlayPause,
                                  onHorizontalDragEnd: _handleHorizontalSwipe,
                                  child: _CoverArt(
                                    coverArtId: song?.coverArt,
                                    semanticLabel: song?.title,
                                  ),
                                )),
                  ),
                ),
                const SizedBox(height: 16),
                _TrackInfo(
                  title: title,
                  artist: artist,
                  album: album,
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
                      : (song?.artistId != null && song!.artistId!.isNotEmpty
                            ? () => NavService.goToArtist(
                                context,
                                ref,
                                song.artistId!,
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
                const SizedBox(height: 16),
                if (!isRadio) ...[
                  _SeekBar(playback: playback),
                  const SizedBox(height: 8),
                ],
                _TransportControls(
                  playback: playback,
                  isRadio: isRadio,
                ),
                const SizedBox(height: 8),
                if (!isRadio)
                  _ActionRow(
                    songId: playback.currentSongId,
                    isLiked: playback.isCurrentSongLiked,
                    showLyrics: _showLyrics,
                    onLyricsToggle: () =>
                        setState(() => _showLyrics = !_showLyrics),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CoverArt extends StatelessWidget {
  const _CoverArt({this.coverArtId, this.semanticLabel});

  final String? coverArtId;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final artSize = screenWidth - 48;
    final clampedSize = artSize.clamp(200.0, 400.0);

    return CoverArtImage(
      coverArtId: coverArtId,
      size: 640,
      width: clampedSize,
      height: clampedSize,
      borderRadius: BorderRadius.circular(12),
      placeholderIcon: Icons.music_note_outlined,
      semanticLabel: semanticLabel,
    );
  }
}

class _RadioCoverArt extends StatelessWidget {
  const _RadioCoverArt({this.artUrl});

  final String? artUrl;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final artSize = screenWidth - 48;
    final clampedSize = artSize.clamp(200.0, 400.0);

    if (artUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          artUrl!,
          width: clampedSize,
          height: clampedSize,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _radioPlaceholder(context, clampedSize),
        ),
      );
    }

    return _radioPlaceholder(context, clampedSize);
  }

  Widget _radioPlaceholder(BuildContext context, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
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
    this.onTitleTap,
    this.onArtistTap,
    this.onAlbumTap,
  });

  final String title;
  final String artist;
  final String album;
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
              color: onTitleTap != null
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onArtistTap,
          child: Text(
            artist,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: onArtistTap != null
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 2),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onAlbumTap,
          child: Text(
            album,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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

    return Column(
      children: <Widget>[
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
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
  const _TransportControls({required this.playback, this.isRadio = false});

  final PlaybackSnapshot playback;
  final bool isRadio;

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
                padding: const EdgeInsets.all(16),
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
                size: 36,
              ),
            ),
          ),
          const SizedBox(width: 16),
          IconButton(
            icon: const Icon(Icons.stop, size: 32),
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
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.skip_previous, size: 32),
          tooltip: l10n.nowPlayingPrevious,
          onPressed: () {
            HapticFeedback.mediumImpact();
            final handler = ref.read(audioHandlerProvider);
            unawaited(handler?.skipToPrevious());
          },
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: isPlaying ? l10n.nowPlayingPause : l10n.nowPlayingPlay,
          child: FilledButton(
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: const EdgeInsets.all(16),
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
              size: 36,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.skip_next, size: 32),
          tooltip: l10n.nowPlayingNext,
          onPressed: () {
            HapticFeedback.mediumImpact();
            final handler = ref.read(audioHandlerProvider);
            unawaited(handler?.skipToNext());
          },
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: Icon(
            repeatIcon,
            color: isRepeatActive
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
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
  });

  final String songId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final lyricsAsync = ref.watch(lyricsProvider(songId));
    final position =
        ref.watch(playbackPositionProvider).asData?.value ??
        ref.watch(playerStateProvider).position;

    return lyricsAsync.when(
      data: (lyrics) => LyricsDisplayWidget(
        lyrics: lyrics,
        currentPosition: position,
        onSeek: (seekPosition) {
          final handler = ref.read(audioHandlerProvider);
          handler?.seek(seekPosition);
        },
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: Text(
          l10n.lyricsNoneAvailable,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends ConsumerStatefulWidget {
  const _ActionRow({
    this.songId,
    this.isLiked = false,
    this.showLyrics = false,
    this.onLyricsToggle,
  });

  final String? songId;
  final bool isLiked;
  final bool showLyrics;
  final VoidCallback? onLyricsToggle;

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

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        ScaleTransition(
          scale: _likeScale,
          child: IconButton(
            icon: Icon(widget.isLiked ? Icons.favorite : Icons.favorite_border),
            color: widget.isLiked
                ? Theme.of(context).colorScheme.primary
                : null,
            tooltip: l10n.nowPlayingStar,
            onPressed: widget.songId == null
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    final handler = ref.read(audioHandlerProvider);
                    handler?.toggleLike();
                  },
          ),
        ),
        IconButton(
          icon: Icon(
            widget.showLyrics ? Icons.lyrics : Icons.lyrics_outlined,
            color: widget.showLyrics
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          tooltip: l10n.nowPlayingLyrics,
          onPressed: widget.songId == null ? null : widget.onLyricsToggle,
        ),
        IconButton(
          icon: const Icon(Icons.queue_music),
          tooltip: l10n.nowPlayingQueue,
          onPressed: () => NavService.showQueue(context),
        ),
        IconButton(
          icon: instantMix.refilling
              ? SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: instantMix.active
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                )
              : Icon(
                  instantMix.active ? Icons.explore : Icons.explore_outlined,
                  color: instantMix.active
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
          tooltip: instantMix.active
              ? l10n.nowPlayingInstantMixActive
              : l10n.nowPlayingInstantMix,
          onPressed: widget.songId == null
              ? null
              : () =>
                    ref.read(instantMixProvider.notifier).toggle(widget.songId),
        ),
        // Smart Queue button — visible only when AudioMuse NV plugin detected.
        if (ref.watch(smartQueueAvailableProvider).asData?.value ?? false)
          _SmartQueueButton(songId: widget.songId),
      ],
    );
  }
}

/// An [IconButton] that shows the Smart Queue sheet or stops an active session.
class _SmartQueueButton extends ConsumerWidget {
  const _SmartQueueButton({this.songId});

  final String? songId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final sq = ref.watch(smartQueueProvider);

    return IconButton(
      icon: sq.refilling
          ? SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: sq.active ? Theme.of(context).colorScheme.primary : null,
              ),
            )
          : Icon(
              sq.active ? Icons.auto_awesome : Icons.auto_awesome_outlined,
              color: sq.active ? Theme.of(context).colorScheme.primary : null,
            ),
      tooltip: sq.active ? l10n.smartQueueActive : l10n.smartQueueButton,
      onPressed: songId == null
          ? null
          : () {
              if (sq.active) {
                ref.read(smartQueueProvider.notifier).deactivate();
              } else {
                showSmartQueueSheet(context, ref, seedSongId: songId!);
              }
            },
    );
  }
}
