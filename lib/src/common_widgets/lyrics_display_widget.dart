import 'package:flutter/material.dart';
import 'package:navis/src/api/models/models.dart';

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
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _lineKeys = <int, GlobalKey>{};
  int? _currentLineIndex;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _updateCurrentLine();
  }

  @override
  void didUpdateWidget(LyricsDisplayWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentPosition != oldWidget.currentPosition) {
      _updateCurrentLine();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _updateCurrentLine() {
    if (!_hasSyncedLyrics) {
      return;
    }

    final structuredLyrics = widget.lyrics.structuredLyrics.firstOrNull;
    if (structuredLyrics == null) {
      return;
    }

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

      if (_autoScroll && newIndex != null) {
        _scrollToLine(newIndex);
      }
    }
  }

  void _scrollToLine(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final key = _lineKeys[index];
      if (key == null) {
        return;
      }
      final currentContext = key.currentContext;
      if (currentContext == null) {
        return;
      }
      Scrollable.ensureVisible(
        currentContext,
        alignment: 0.4,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  GlobalKey _keyForLine(int index) {
    return _lineKeys.putIfAbsent(index, GlobalKey.new);
  }

  bool get _hasSyncedLyrics {
    final structured = widget.lyrics.structuredLyrics;
    if (structured.isEmpty) {
      return false;
    }
    return structured.first.line.any((line) => line.start != null);
  }

  bool get _hasUnsyncedLyrics {
    final unsynced = widget.lyrics.value;
    return unsynced != null && unsynced.trim().isNotEmpty;
  }

  LyricsDisplayMode get _displayMode {
    if (_hasSyncedLyrics) {
      return LyricsDisplayMode.synced;
    }
    if (_hasUnsyncedLyrics) {
      return LyricsDisplayMode.unsynced;
    }
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
        if (notification is ScrollStartNotification) {
          if (notification.dragDetails != null) {
            setState(() {
              _autoScroll = false;
            });
          }
        }
        return false;
      },
      child: Stack(
        children: [
          ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 100),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              final isActive = index == _currentLineIndex;

              return InkWell(
                key: _keyForLine(index),
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
                  setState(() {
                    _autoScroll = true;
                  });
                  final lineIndex = _currentLineIndex;
                  _currentLineIndex = null;
                  _updateCurrentLine();
                  if (_currentLineIndex == null && lineIndex != null) {
                    _scrollToLine(lineIndex);
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
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          height: 1.8,
        ),
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
            'No lyrics available',
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
