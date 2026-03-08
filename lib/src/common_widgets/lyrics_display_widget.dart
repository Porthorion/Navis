import 'dart:async';

import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

enum LyricsDisplayMode { synced, unsynced, none }

class LyricsDisplayWidget extends StatefulWidget {
  const LyricsDisplayWidget({
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
    if (widget.currentPosition != oldWidget.currentPosition) {
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
    if (!_itemScrollController.isAttached) {
      // Controller not yet attached — retry after the first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _itemScrollController.isAttached) {
          _scrollToLine(index, animate: false);
        }
      });
      return;
    }

    if (animate) {
      unawaited(
        _itemScrollController.scrollTo(
          index: index,
          alignment: 0.4,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
        ),
      );
    } else {
      _itemScrollController.jumpTo(index: index, alignment: 0.4);
    }
  }

  void _startAutoScrollReengageTimer() {
    _autoScrollReengageTimer?.cancel();
    _autoScrollReengageTimer = Timer(_autoScrollReengageDelay, () {
      if (!mounted) return;
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
        final horizontalPadding = (constraints.maxWidth * 0.06)
            .clamp(20.0, 48.0)
            .toDouble();
        final verticalPadding = (inactiveFontSize * 0.65)
            .clamp(10.0, 20.0)
            .toDouble();

        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              // User started a manual drag - pause auto-scroll.
              _autoScrollReengageTimer?.cancel();
              if (_autoScroll) {
                setState(() => _autoScroll = false);
              }
            } else if (notification is ScrollEndNotification && !_autoScroll) {
              // User lifted finger - start grace-period timer before re-engaging.
              _startAutoScrollReengageTimer();
            }
            return false;
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
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withValues(
                                      alpha: 0.6,
                                    ),
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
        final horizontalPadding = (constraints.maxWidth * 0.06)
            .clamp(20.0, 56.0)
            .toDouble();
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
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  height: 1.8,
                  fontSize: fontSize,
                ),
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
    return (synced - 2).clamp(15.0, 28.0).toDouble();
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
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
              ),
              textAlign: TextAlign.center,
            ),
          if (attribution != null && attribution.trim().isNotEmpty)
            Text(
              attribution,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
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
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.of(context)!.lyricsNoneAvailable,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
