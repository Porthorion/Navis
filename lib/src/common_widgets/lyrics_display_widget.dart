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
    super.key,
  });

  final LyricsList lyrics;
  final Duration currentPosition;
  final void Function(Duration position)? onSeek;

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

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          // User started a manual drag – pause auto-scroll.
          _autoScrollReengageTimer?.cancel();
          if (_autoScroll) {
            setState(() => _autoScroll = false);
          }
        } else if (notification is ScrollEndNotification && !_autoScroll) {
          // User lifted finger – start grace-period timer before re-engaging.
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
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              final isActive = index == _currentLineIndex;

              return InkWell(
                onTap: widget.onSeek != null && line.start != null
                    ? () => widget.onSeek!(Duration(milliseconds: line.start!))
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Text(
                    line.value ?? '',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.6),
                      fontWeight: isActive
                          ? FontWeight.bold
                          : FontWeight.normal,
                      fontSize: isActive ? 18 : 16,
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
  }

  Widget _buildUnsyncedLyrics(BuildContext context) {
    final unsyncedLyrics = widget.lyrics.value ?? '';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Text(
        unsyncedLyrics,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
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
