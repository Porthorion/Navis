import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_track_row.dart';

/// Logical index of the playing row in [queueIds], or null when the playback
/// snapshot does not point into this queue (radio, loading, stale index).
int? queueCurrentIndex(PlaybackSnapshot playback, List<String> queueIds) {
  final index = playback.currentIndex;
  if (queueActionsDisabled(playback) ||
      index == null ||
      index < 0 ||
      index >= queueIds.length) {
    return null;
  }
  return index;
}

/// Wraps a queue list and, once per open, jumps it so the [currentIndex] row
/// is vertically centred (clamped to the list ends).
///
/// Rows are built lazily, so the first pass jumps to an estimate from the
/// measured row extent and a second frame refines it with
/// [Scrollable.ensureVisible] on the real row. Both are instant jumps, so
/// reduced motion needs no special case. It never runs again after the first
/// attempt or after the user scrolls, and never touches item keys, so
/// reordering and swipe-to-remove are unaffected.
class QueueCurrentRowCentering extends StatefulWidget {
  const new({required this.currentIndex, required this.child, super.key});

  final int? currentIndex;
  final Widget child;

  @override
  State<QueueCurrentRowCentering> createState() =>
      _QueueCurrentRowCenteringState();
}

class _QueueCurrentRowCenteringState extends State<QueueCurrentRowCentering> {
  /// Frames a centring attempt may take to converge: rows resolve their song
  /// metadata after the first frame and change height, shifting the target.
  static const _maxPasses = 8;

  bool _started = false;
  bool _cancelled = false;
  bool _programmatic = false;

  @override
  Widget build(BuildContext context) {
    final index = widget.currentIndex;
    if (!_started && index != null) {
      _started = true;
      SchedulerBinding.instance.addPostFrameCallback((_) => _pass(index, 0));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (!_programmatic && notification.depth == 0) _cancelled = true;
        return false;
      },
      child: widget.child,
    );
  }

  Element? _row(int? index) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is QueueTrackRow && (index == null || widget.index == index)) {
        found = element;
        return;
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return found;
  }

  /// One centring pass: reveal the real row when it is built, otherwise jump
  /// to an estimate from the measured row extent. Repeats on the next frame
  /// until the offset stops moving.
  void _pass(int index, int pass, [double? previous]) {
    if (!mounted || _cancelled) return;
    final row = _row(index);
    final any = row ?? _row(null);
    final position = any == null ? null : Scrollable.maybeOf(any)?.position;
    final box = any?.renderObject;
    if (position == null || !position.hasPixels || box is! RenderBox) return;
    _programmatic = true;
    try {
      if (row != null) {
        Scrollable.ensureVisible(row, alignment: 0.5);
      } else if (box.hasSize) {
        final extent = box.size.height;
        position.jumpTo(
          (index * extent + extent / 2 - position.viewportDimension / 2).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
      }
    } finally {
      _programmatic = false;
    }
    if (pass + 1 >= _maxPasses ||
        (row != null && previous == position.pixels)) {
      return;
    }
    final pixels = position.pixels;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => _pass(index, pass + 1, pixels))
      ..scheduleFrame();
  }
}
