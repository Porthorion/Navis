import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

enum LyricsDisplayMode { synced, unsynced, none }

/// The start of the synced line active at [position], or -1 ms before the
/// first line (and for unsynced lyrics).
///
/// Callers pass this instead of the raw playback position so that
/// [LyricsDisplayWidget] is rebuilt when the active line changes, not on every
/// 5-10 Hz position tick.
Duration lyricsActiveLinePosition(LyricsList? lyrics, Duration position) {
  const beforeFirstLine = Duration(milliseconds: -1);
  final lines = lyrics?.structuredLyrics.firstOrNull?.line;
  if (lines == null || lines.isEmpty) return beforeFirstLine;
  final positionMs = position.inMilliseconds;
  // Lines are ordered by start time; find the last one that has started.
  var low = 0;
  var high = lines.length - 1;
  int? active;
  while (low <= high) {
    final middle = (low + high) >> 1;
    final start = lines[middle].start ?? 0;
    if (start <= positionMs) {
      active = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  if (active == null) return beforeFirstLine;
  return Duration(milliseconds: lines[active].start ?? 0);
}

class LyricsDisplayWidget extends StatefulWidget {
  const new({
    required this.lyrics,
    required this.currentPosition,
    this.onSeek,
    this.sourceLabel,
    this.attribution,
    super.key,
  });

  final LyricsList lyrics;
  final Duration currentPosition;
  final void Function(Duration position)? onSeek;
  final String? sourceLabel;
  final String? attribution;

  @override
  State<LyricsDisplayWidget> createState() => _LyricsDisplayWidgetState();
}

class _LyricsDisplayWidgetState extends State<LyricsDisplayWidget> {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  int? _currentLineIndex;
  bool _autoScroll = true;
  bool _manualScrollActive = false;
  bool _panZoomActive = false;
  bool _followAnimationActive = false;
  int _scrollRevision = 0;
  Timer? _autoScrollReengageTimer;

  /// Grace period before auto-scroll re-engages after a user interaction.
  static const _autoScrollReengageDelay = Duration(milliseconds: 2500);

  @override
  void initState() {
    super.initState();
    _updateCurrentLine(animate: false);
  }

  @override
  void didUpdateWidget(LyricsDisplayWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lyrics != oldWidget.lyrics) {
      _pauseFollowing();
      _autoScroll = true;
      _manualScrollActive = _panZoomActive = false;
      _currentLineIndex = null;
    }
    if (widget.currentPosition != oldWidget.currentPosition ||
        widget.lyrics != oldWidget.lyrics) {
      _updateCurrentLine(animate: true);
    }
  }

  @override
  void dispose() {
    _autoScrollReengageTimer?.cancel();
    super.dispose();
  }

  void _updateCurrentLine({required bool animate}) {
    if (!_hasSyncedLyrics) return;

    final structuredLyrics = widget.lyrics.structuredLyrics.firstOrNull;
    if (structuredLyrics == null) return;

    final lines = structuredLyrics.line;
    final positionMs = widget.currentPosition.inMilliseconds;

    int? newIndex;
    for (var i = 0; i < lines.length; i++) {
      final lineStart = lines[i].start ?? 0;
      if (positionMs >= lineStart) {
        newIndex = i;
      } else {
        break;
      }
    }

    if (newIndex != _currentLineIndex) {
      setState(() {
        _currentLineIndex = newIndex;
      });
      // Only scroll when the active line actually changes, not on every tick.
      if (_autoScroll && newIndex != null) {
        _scrollToLine(newIndex, animate: animate);
      }
    }
  }

  void _scrollToLine(int index, {required bool animate}) {
    final revision = ++_scrollRevision;
    if (!_itemScrollController.isAttached) {
      // Controller not yet attached — retry after the first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _autoScroll &&
            revision == _scrollRevision &&
            _currentLineIndex == index &&
            _itemScrollController.isAttached) {
          _scrollToLine(index, animate: false);
        }
      });
      return;
    }

    if (animate) {
      _followAnimationActive = true;
      unawaited(
        _itemScrollController
            .scrollTo(
              index: index,
              alignment: 0.4,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
            )
            .whenComplete(() {
              if (revision == _scrollRevision) _followAnimationActive = false;
            }),
      );
    } else {
      _itemScrollController.jumpTo(index: index, alignment: 0.4);
    }
  }

  void _pauseFollowing({bool stopAnimation = true}) {
    _autoScrollReengageTimer?.cancel();
    _scrollRevision++;
    if (stopAnimation &&
        _followAnimationActive &&
        _itemScrollController.isAttached) {
      // Jump to the same visible item's alignment to stop an outstanding
      // automatic animation without pulling the reader back to the song.
      final visible = _itemPositionsListener.itemPositions.value
          .where(
            (item) => item.itemLeadingEdge >= 0 && item.itemLeadingEdge < 1,
          )
          .firstOrNull;
      if (visible != null) {
        _itemScrollController.jumpTo(
          index: visible.index,
          alignment: visible.itemLeadingEdge,
        );
      }
    }
    _followAnimationActive = false;
    if (_autoScroll) setState(() => _autoScroll = false);
  }

  void _startAutoScrollReengageTimer() {
    _autoScrollReengageTimer?.cancel();
    _autoScrollReengageTimer = Timer(_autoScrollReengageDelay, () {
      if (!mounted || _manualScrollActive) return;
      setState(() {
        _autoScroll = true;
      });
      if (_currentLineIndex != null) {
        _scrollToLine(_currentLineIndex!, animate: true);
      }
    });
  }

  bool get _hasSyncedLyrics {
    final structured = widget.lyrics.structuredLyrics;
    if (structured.isEmpty) return false;
    return structured.first.line.any((line) => line.start != null);
  }

  bool get _hasUnsyncedLyrics {
    final unsynced = widget.lyrics.value;
    return unsynced != null && unsynced.trim().isNotEmpty;
  }

  LyricsDisplayMode get _displayMode {
    if (_hasSyncedLyrics) return LyricsDisplayMode.synced;
    if (_hasUnsyncedLyrics) return LyricsDisplayMode.unsynced;
    return LyricsDisplayMode.none;
  }

  @override
  Widget build(BuildContext context) {
    return switch (_displayMode) {
      LyricsDisplayMode.synced => _buildSyncedLyrics(context),
      LyricsDisplayMode.unsynced => _buildUnsyncedLyrics(context),
      LyricsDisplayMode.none => _buildNoLyrics(context),
    };
  }

  Widget _buildSyncedLyrics(BuildContext context) {
    final structuredLyrics = widget.lyrics.structuredLyrics.first;
    final lines = structuredLyrics.line;
    final hasFooter = _hasFooter;

    return LayoutBuilder(
      builder: (context, constraints) {
        final inactiveFontSize = _resolveSyncedFontSize(constraints.maxWidth);
        final activeFontSize = inactiveFontSize + 2;
        final horizontalPadding = (constraints.maxWidth * 0.06).clamp(
          20.0,
          48.0,
        );
        final verticalPadding = (inactiveFontSize * 0.65).clamp(10.0, 20.0);

        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              _manualScrollActive = true;
              // A touch drag already replaced the automatic scroll activity.
              _pauseFollowing(stopAnimation: false);
            } else if (notification is ScrollEndNotification &&
                !_autoScroll &&
                !_panZoomActive) {
              _manualScrollActive = false;
              _startAutoScrollReengageTimer();
            }
            return false;
          },
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _pauseFollowing();
                if (!_manualScrollActive) _startAutoScrollReengageTimer();
              }
            },
            onPointerPanZoomStart: (_) {
              _manualScrollActive = _panZoomActive = true;
              _pauseFollowing();
            },
            onPointerPanZoomUpdate: (_) => _pauseFollowing(),
            onPointerPanZoomEnd: (_) {
              _manualScrollActive = _panZoomActive = false;
              _startAutoScrollReengageTimer();
            },
            child: Stack(
              children: [
                ScrollablePositionedList.builder(
                  itemScrollController: _itemScrollController,
                  itemPositionsListener: _itemPositionsListener,
                  padding: const EdgeInsets.symmetric(vertical: 100),
                  itemCount: lines.length + (hasFooter ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (hasFooter && index == lines.length) {
                      return _buildFooter(context);
                    }
                    final line = lines[index];
                    final isActive = index == _currentLineIndex;

                    return InkWell(
                      onTap: widget.onSeek != null && line.start != null
                          ? () => widget.onSeek!(
                              Duration(milliseconds: line.start!),
                            )
                          : null,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: horizontalPadding,
                          vertical: verticalPadding,
                        ),
                        child: Text(
                          line.value ?? '',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: isActive
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.onSurface
                                          .withValues(alpha: 0.6),
                                fontWeight: isActive
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                fontSize: isActive
                                    ? activeFontSize
                                    : inactiveFontSize,
                              ),
                        ),
                      ),
                    );
                  },
                ),
                if (!_autoScroll)
                  Positioned(
                    bottom: 16,
                    right: 16,
                    child: FloatingActionButton.small(
                      // Material's small FAB corner (12 px) in Pill; the
                      // themed FAB shape is the regular 16 px one.
                      shape: RoundedRectangleBorder(
                        borderRadius: NavisShapeData.of(context).scaledAll(12),
                      ),
                      onPressed: () {
                        _autoScrollReengageTimer?.cancel();
                        setState(() => _autoScroll = true);
                        if (_currentLineIndex != null) {
                          _scrollToLine(_currentLineIndex!, animate: true);
                        }
                      },
                      child: const Icon(Icons.my_location),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildUnsyncedLyrics(BuildContext context) {
    final unsyncedLyrics = widget.lyrics.value ?? '';
    final hasFooter = _hasFooter;

    return LayoutBuilder(
      builder: (context, constraints) {
        final fontSize = _resolveUnsyncedFontSize(constraints.maxWidth);
        final horizontalPadding = (constraints.maxWidth * 0.06).clamp(
          20.0,
          56.0,
        );
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            24,
            horizontalPadding,
            24,
          ),
          child: Column(
            children: <Widget>[
              Text(
                unsyncedLyrics,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(height: 1.8, fontSize: fontSize),
              ),
              if (hasFooter) ...<Widget>[
                const SizedBox(height: 20),
                _buildFooter(context),
              ],
            ],
          ),
        );
      },
    );
  }

  double _resolveSyncedFontSize(double width) {
    if (width >= 1500) return 30;
    if (width >= 1200) return 27;
    if (width >= 980) return 24;
    if (width >= 760) return 21;
    if (width >= 560) return 18;
    return 16;
  }

  double _resolveUnsyncedFontSize(double width) {
    final synced = _resolveSyncedFontSize(width);
    return (synced - 2).clamp(15.0, 28.0);
  }

  bool get _hasFooter {
    final source = widget.sourceLabel;
    final attribution = widget.attribution;
    return (source != null && source.trim().isNotEmpty) ||
        (attribution != null && attribution.trim().isNotEmpty);
  }

  Widget _buildFooter(BuildContext context) {
    final source = widget.sourceLabel;
    final attribution = widget.attribution;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        children: <Widget>[
          if (source != null && source.trim().isNotEmpty)
            Text(
              source,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.85),
              ),
              textAlign: TextAlign.center,
            ),
          if (attribution != null && attribution.trim().isNotEmpty)
            Text(
              attribution,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.75),
              ),
              textAlign: TextAlign.center,
            ),
        ],
      ),
    );
  }

  Widget _buildNoLyrics(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lyrics_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.of(context)!.lyricsNoneAvailable,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
