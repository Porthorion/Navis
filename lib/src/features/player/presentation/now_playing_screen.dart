import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';
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
    final mediaQuery = MediaQuery.of(context);
    final rootViewPadding = MediaQueryData.fromView(
      View.of(context),
    ).viewPadding;
    final bottomSafeInset = math.max(
      mediaQuery.padding.bottom,
      rootViewPadding.bottom,
    );

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
          bottom: false,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomSafeInset),
            child: Column(
              children: <Widget>[
                const _NowPlayingHandle(),
                Expanded(
                  child: _NowPlayingBody(
                    playback: playback,
                    song: playback.isRadioMode ? null : song,
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
  SongsTableData? song,
) {
  final l10n = AppLocalizations.of(context)!;
  final playbackSpeed =
      ref.read(appSettingsProvider).asData?.value.playbackSpeed ?? 1;

  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    builder: (sheetContext) => SafeArea(
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
        ],
      ),
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
    final albumDetails =
        !isRadio && song?.albumId != null && song!.albumId!.isNotEmpty
        ? ref.watch(albumProvider(song.albumId!)).asData?.value?.album
        : null;
    final currentMediaItem = ref.watch(currentMediaItemProvider).asData?.value;
    final playbackSpeed =
        ref.watch(appSettingsProvider).asData?.value.playbackSpeed ?? 1;

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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: <Widget>[
          const SizedBox(height: 8),
          Expanded(
            child: Center(
              child: isRadio
                  ? _RadioCoverArt(artUrl: radioMeta?.nowPlayingArtUrl)
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _showLyrics && playback.currentSongId != null
                          ? _InlineLyrics(
                              key: const ValueKey('lyrics'),
                              songId: playback.currentSongId!,
                            )
                          : GestureDetector(
                              key: const ValueKey('cover'),
                              onTap: _togglePlayPause,
                              onHorizontalDragEnd: _handleHorizontalSwipe,
                              child: _CoverArt(
                                coverArtId: song?.coverArt,
                                semanticLabel: song?.title,
                              ),
                            ),
                    ),
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
          if (!isRadio) ...[
            const SizedBox(height: 12),
            _NowPlayingInfoPanel(
              song: song,
              album: albumDetails,
              playback: playback,
              currentMediaItem: currentMediaItem,
              playbackSpeed: playbackSpeed,
            ),
          ],
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
              song: song,
              songId: playback.currentSongId,
              isLiked: playback.isCurrentSongLiked,
              showLyrics: _showLyrics,
              onLyricsToggle: () => setState(() => _showLyrics = !_showLyrics),
            ),
          const SizedBox(height: 8),
        ],
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
    final mq = MediaQuery.of(context).size;
    final widthBased = mq.width - 48;
    // Use 42% of screen height as a cap so controls aren't squeezed.
    final heightBased = mq.height * 0.42;
    final artSize = (widthBased < heightBased ? widthBased : heightBased).clamp(
      180.0,
      600.0,
    );

    return CoverArtImage(
      coverArtId: coverArtId,
      size: 640,
      width: artSize,
      height: artSize,
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
    final mq = MediaQuery.of(context).size;
    final widthBased = mq.width - 48;
    final heightBased = mq.height * 0.42;
    final artSize = (widthBased < heightBased ? widthBased : heightBased).clamp(
      180.0,
      600.0,
    );

    if (artUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          artUrl!,
          width: artSize,
          height: artSize,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _radioPlaceholder(context, artSize),
        ),
      );
    }

    return _radioPlaceholder(context, artSize);
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

class _NowPlayingInfoPanel extends StatefulWidget {
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
  State<_NowPlayingInfoPanel> createState() => _NowPlayingInfoPanelState();
}

class _NowPlayingInfoPanelState extends State<_NowPlayingInfoPanel> {
  int _pageIndex = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final pages = <_NowPlayingInfoPage>[
      _NowPlayingInfoPage(
        icon: Icons.info_outline,
        semanticLabel: l10n.nowPlayingAudioQuality,
        value: _formatAudioQuality(
          song: widget.song,
          mediaItem: widget.currentMediaItem,
        ),
      ),
      _NowPlayingInfoPage(
        icon: Icons.queue_music_outlined,
        semanticLabel: l10n.queueTitle,
        value: _formatQueuePosition(l10n, widget.playback),
      ),
      _NowPlayingInfoPage(
        icon: Icons.calendar_today_outlined,
        semanticLabel: l10n.nowPlayingReleaseDate,
        value: _formatReleaseDate(widget.song, widget.album),
      ),
      _NowPlayingInfoPage(
        icon: Icons.speed_outlined,
        semanticLabel: l10n.playbackSettingsPlaybackSpeedLabel,
        value: _formatPlaybackRate(widget.playbackSpeed),
      ),
    ];
    final activeIndex = _pageIndex % pages.length;
    final page = pages[activeIndex];
    final colors = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () =>
            setState(() => _pageIndex = (_pageIndex + 1) % pages.length),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: <Widget>[
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: Row(
                  key: ValueKey<String>('${page.semanticLabel}:${page.value}'),
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      page.icon,
                      size: 14,
                      color: colors.onSurfaceVariant.withValues(alpha: 0.72),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        page.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant.withValues(
                            alpha: 0.82,
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
  });

  final IconData icon;
  final String semanticLabel;
  final String value;
}

String _formatAudioQuality({
  required SongsTableData? song,
  required MediaItem? mediaItem,
}) {
  final extras = mediaItem?.extras;
  final format =
      (extras?['resolvedFormat'] as String?)?.trim().toUpperCase() ??
      song?.suffix?.trim().toUpperCase() ??
      _inferAudioFormat(song?.contentType);
  final bitRate = (extras?['resolvedBitRate'] as int?) ?? song?.bitRate;
  final descriptor = _audioDescriptor(format);

  final parts = <String>[
    if (format != null && format.isNotEmpty) format,
    if (descriptor != null) descriptor,
    if (bitRate != null && bitRate > 0) _formatBitRate(bitRate),
  ];

  if (parts.isEmpty) {
    return '-';
  }
  return parts.join(' • ');
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

String? _audioDescriptor(String? format) {
  if (format == null || format.isEmpty) {
    return null;
  }

  return switch (format.toLowerCase()) {
    'flac' || 'alac' || 'wav' || 'aiff' || 'ape' => 'Lossless',
    'mp3' || 'aac' || 'ogg' || 'opus' || 'm4a' => 'Compressed',
    _ => null,
  };
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
    super.key,
  });

  final String songId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

        return Center(
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
      },
    );
  }
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
                  : (value) => setState(
                      () => _speed = _normalizePlaybackSpeed(value),
                    ),
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
                      : () => setState(() => _speed = 1),
                  child: Text(l10n.playbackSettingsResetAction),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _isSaving ? null : _save,
                  child: Text(l10n.playbackSettingsSaveAction),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
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
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
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
}

class _ActionRow extends ConsumerStatefulWidget {
  const _ActionRow({
    this.song,
    this.songId,
    this.isLiked = false,
    this.showLyrics = false,
    this.onLyricsToggle,
  });

  final SongsTableData? song;
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
          onTap: () => NavService.showQueue(context, ref),
        ),
        _NowPlayingActionButton(
          icon: mixIcon,
          label: l10n.nowPlayingInstantMixLabel,
          onTap: widget.songId == null
              ? null
              : () {
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
          label: l10n.nowPlayingStar,
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
          onTap: () => _showNowPlayingSettingsSheet(context, ref, widget.song),
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
