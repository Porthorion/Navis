part of 'now_playing_screen.dart';

/// The Now Playing cover, shaped by the Now Playing Art Shape setting.
class _CoverArt extends StatelessWidget {
  const new({
    this.coverArtId,
    this.semanticLabel,
    this.isExternalSource = false,
  });

  final String? coverArtId;
  final String? semanticLabel;
  final bool isExternalSource;

  @override
  Widget build(BuildContext context) {
    return CoverArtImage(
      coverArtId: coverArtId,
      size: kCoverArtStandardSize,
      shape: ArtworkShapeRole.nowPlaying,
      semanticLabel: semanticLabel,
      loadPriority: CoverArtLoadPriority.critical,
      isExternalSource: isExternalSource,
      remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
    );
  }
}

class _RadioCoverArt extends ConsumerWidget {
  const new({super.key, this.artUrl, this.maxSize});

  final String? artUrl;
  final double? maxSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final npShape = ref.watch(nowPlayingArtShapeProvider);
    final npRadius = artworkBorderRadius(npShape, extent: double.infinity);
    final explicitMaxSize = maxSize;
    if (explicitMaxSize != null) {
      final artSize = explicitMaxSize.clamp(180.0, 680.0);
      if (artUrl != null) {
        return ClipRRect(
          borderRadius: npRadius,
          child: ExternalArtworkImage(
            url: artUrl!,
            width: artSize,
            height: artSize,
            fit: BoxFit.cover,
            feature: IntegrationFeature.radioNowPlaying,
            fallbackBuilder: (context) =>
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
        child: ExternalArtworkImage(
          url: artUrl!,
          width: artSize,
          height: artSize,
          fit: BoxFit.cover,
          feature: IntegrationFeature.radioNowPlaying,
          fallbackBuilder: (context) =>
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
  const new({
    super.key,
    required this.title,
    required this.artist,
    required this.album,
    this.compact = false,
    this.onTitleTap,
    this.onArtistTap,
    this.onAlbumTap,
    this.artistLinks,
    this.isExternalSource = false,
    this.phone,
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
  final bool isExternalSource;

  /// The portrait phone layout; its type steps replace [compact]'s and its
  /// short class folds the album into the artist line.
  final NowPlayingPhoneLayout? phone;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final links = artistLinks;
    final phone = this.phone;
    final titleSize = phone?.titleSize ?? (compact ? 20.0 : null);
    final artistSize = phone?.artistSize ?? (compact ? 15.0 : null);
    final albumSize = phone?.albumSize ?? (compact ? 13.0 : null);
    final titleGap = phone?.titleGap ?? (compact ? 2.0 : 4.0);
    final albumGap = phone?.albumGap ?? (compact ? 1.0 : 2.0);
    final foldAlbum = phone?.foldAlbum ?? false;
    final titleStyle = textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.bold,
      fontSize: titleSize,
      color: onTitleTap != null
          ? NowPlayingArtworkLayerScope.accentOf(context)
          : null,
    );
    final artistStyle = textTheme.bodyLarge?.copyWith(
      fontSize: artistSize,
      color: colorScheme.onSurfaceVariant,
    );
    final albumStyle = textTheme.bodyMedium?.copyWith(
      fontSize: albumSize,
      color: colorScheme.onSurfaceVariant,
    );
    // Phone: fixed-height lines, so Arabic or CJK fallback fonts cannot make
    // the block taller than the layout budgeted.
    final titleStrut = phone?.titleStrut(titleStyle!);
    final artistStrut = phone?.artistStrut(artistStyle!);
    final albumStrut = phone?.albumStrut(albumStyle!);
    return Column(
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTitleTap,
          child: Text(
            title,
            style: titleStyle,
            strutStyle: titleStrut,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
        SizedBox(height: titleGap),
        if (isExternalSource) ...<Widget>[
          const RemoteSourceIndicator(
            variant: RemoteSourceIndicatorVariant.inline,
          ),
          SizedBox(height: titleGap),
        ],
        if (links != null && links.isNotEmpty && phone != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, link) in links.indexed) ...<Widget>[
                Flexible(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: link.onTap,
                    child: Text(
                      '${i > 0 ? ', ' : ''}${link.name}',
                      style: artistStyle,
                      strutStyle: artistStrut,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ],
          )
        else if (links != null && links.isNotEmpty)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 0,
            runSpacing: 0,
            children: [
              for (final (i, link) in links.indexed) ...<Widget>[
                if (i > 0)
                  Text(', ', style: artistStyle, strutStyle: artistStrut),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: link.onTap,
                  child: Text(
                    link.name,
                    style: artistStyle,
                    strutStyle: artistStrut,
                  ),
                ),
              ],
            ],
          )
        else if (foldAlbum)
          // One "Artist · Album" line; each part keeps its own tap target and
          // ellipsizes on its own.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onArtistTap,
                  child: Text(
                    artist,
                    style: artistStyle,
                    strutStyle: artistStrut,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (album.isNotEmpty) ...<Widget>[
                Text(' \u00b7 ', style: artistStyle, strutStyle: artistStrut),
                Flexible(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onAlbumTap,
                    child: Text(
                      album,
                      style: artistStyle,
                      strutStyle: artistStrut,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
              style: artistStyle,
              strutStyle: artistStrut,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        if (!foldAlbum) ...<Widget>[
          SizedBox(height: albumGap),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onAlbumTap,
            child: Text(
              album,
              style: albumStyle,
              strutStyle: albumStrut,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ],
    );
  }
}

class _NowPlayingInfoPanel extends ConsumerStatefulWidget {
  const new({
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
      adjustments: ref.watch(playbackAdjustmentsProvider).asData?.value.values,
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
    final reduceMotion = MotionPolicy.of(context).reduceMotion;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: NavisShapeData.of(context).xlAll,
        onTap: () => setState(() {
          _pageIndex = (_pageIndex + 1) % pages.length;
          _showInlineRatingEditor = false;
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: <Widget>[
              AnimatedSwitcher(
                key: const ValueKey<String>('nowPlayingInfoSwitcher'),
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
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
                      key: const ValueKey<String>('nowPlayingInfoSize'),
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
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
                                        showAppNotice(
                                          context,
                                          message: l10n.ratingUpdateFailed,
                                          level: AppNoticeLevel.error,
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
                                child: _NowPlayingInfoValue(
                                  page: page,
                                  maxLines: 1,
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
              if (pages.length > 1) ...<Widget>[
                const SizedBox(height: 6),
                // Shows that tapping cycles through more details.
                ExcludeSemantics(
                  child: Row(
                    key: const ValueKey<String>('nowPlayingInfoPageDots'),
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (var i = 0; i < pages.length; i++)
                        AnimatedContainer(
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          width: i == activeIndex ? 12 : 4,
                          height: 4,
                          decoration: BoxDecoration(
                            borderRadius: NavisRadius.pillAll,
                            color: colors.onSurfaceVariant.withValues(
                              alpha: i == activeIndex ? 0.8 : 0.3,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NowPlayingInfoPage {
  const new({
    required this.icon,
    required this.semanticLabel,
    required this.value,
    this.valueLeadingIcon,
    this.valueLeadingIconSemanticLabel,
    this.isRatingPage = false,
  });

  final IconData icon;
  final String semanticLabel;
  final String value;
  final IconData? valueLeadingIcon;
  final String? valueLeadingIconSemanticLabel;
  final bool isRatingPage;
}

List<_NowPlayingInfoPage> _buildNowPlayingInfoPages({
  required AppLocalizations l10n,
  required SongsTableData? song,
  required AlbumsTableData? album,
  required PlaybackSnapshot playback,
  required MediaItem? currentMediaItem,
  required double playbackSpeed,
  PlaybackAdjustments? adjustments,
}) {
  final transcodingApplied =
      currentMediaItem?.extras?['bridgeFormat'] != null ||
      currentMediaItem?.extras?['transcodingApplied'] == true;
  return <_NowPlayingInfoPage>[
    _NowPlayingInfoPage(
      icon: Icons.info_outline,
      semanticLabel: l10n.nowPlayingAudioQuality,
      value: _formatAudioQuality(song: song, mediaItem: currentMediaItem),
      valueLeadingIcon: transcodingApplied ? Icons.transform : null,
      valueLeadingIconSemanticLabel: transcodingApplied
          ? l10n.nowPlayingTranscodedPlayback
          : null,
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
      semanticLabel: l10n.playbackSpeedPitchTitle,
      value: formatPlaybackAdjustments(
        l10n,
        adjustments ?? PlaybackAdjustments(speed: playbackSpeed),
      ),
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
  const new({
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
      adjustments: ref.watch(playbackAdjustmentsProvider).asData?.value.values,
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
    final valueStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: colors.onSurface, fontWeight: FontWeight.w500);
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
  const new({
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
              _NowPlayingInfoValue(page: page, maxLines: 2, style: valueStyle),
            ],
          ),
        ),
      ],
    );
  }
}

class _NowPlayingInfoValue extends StatelessWidget {
  const new({
    required this.page,
    required this.maxLines,
    required this.style,
    this.textAlign,
  });

  final _NowPlayingInfoPage page;
  final int maxLines;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final leadingIcon = page.valueLeadingIcon;
    if (leadingIcon == null) {
      return Text(
        page.value,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
        style: style,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          label: page.valueLeadingIconSemanticLabel,
          child: ExcludeSemantics(
            child: Icon(
              leadingIcon,
              size: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.72),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            page.value,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            textAlign: textAlign,
            style: style,
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
  final bridging = extras?['bridgeFormat'] != null;
  final resolvedFormat =
      ((extras?['bridgeFormat'] ?? extras?['resolvedFormat']) as String?)
          ?.trim();
  final formatLabel =
      _formatAudioFormatLabel(resolvedFormat) ??
      song?.suffix?.trim().toUpperCase() ??
      _inferAudioFormat(song?.contentType);
  final bitRate =
      (extras?['bridgeBitRate'] as int?) ??
      (extras?['resolvedBitRate'] as int?) ??
      song?.bitRate;
  final sampleRate = bridging
      ? null
      : _readSampleRateFromExtras(extras) ?? song?.sampleRate;

  final parts = <String>[
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

String? _formatAudioFormatLabel(String? format) {
  final normalized = format?.trim();
  if (normalized != null && normalized.isNotEmpty) {
    if (normalized.toLowerCase() == 'transcoded') {
      return null;
    }
    return normalized.toUpperCase();
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
