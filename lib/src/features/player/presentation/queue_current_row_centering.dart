import 'package:flutter/rendering.dart';
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
/// Rows are built lazily, so a pass without the real row jumps to an estimate
/// stepped from a built row and later frames refine it with
/// [Scrollable.ensureVisible] on the real row. Rows resolve their song
/// metadata asynchronously and can grow a line, pushing the current row, so
/// refinement keeps running for a short window after opening. All passes are
/// instant jumps, so reduced motion needs no special case. It stops for good
/// once the user touches or scrolls the list, and never touches item keys, so
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
  /// How long after opening rows may still change height (metadata loads
  /// from the database) and the current row is re-centred.
  // ponytail: fixed window; listen to row size changes if loads get slower.
  static const _settleWindow = Duration(milliseconds: 1200);

  bool _started = false;
  bool _cancelled = false;

  @override
  Widget build(BuildContext context) {
    final index = widget.currentIndex;
    if (!_started && index != null) {
      _started = true;
      SchedulerBinding.instance.addPostFrameCallback(
        (timeStamp) => _pass(index, timeStamp, timeStamp),
      );
    }
    // Only the user's own input stops it: layout corrections after rows grow
    // also send scroll notifications.
    return Listener(
      onPointerDown: (_) => _cancelled = true,
      onPointerSignal: (_) => _cancelled = true,
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
  /// to an estimate from the measured row extent. Repeats every frame until
  /// [_settleWindow] has passed.
  void _pass(int index, Duration started, Duration now) {
    if (!mounted || _cancelled) return;
    final row = _row(index);
    final any = row ?? _row(null);
    final position = any == null ? null : Scrollable.maybeOf(any)?.position;
    final box = any?.renderObject;
    if (position == null || !position.hasPixels || box is! RenderBox) return;
    if (row != null) {
      Scrollable.ensureVisible(row, alignment: 0.5);
    } else if (box.hasSize) {
      // Step from a built row toward the target, using its height per row.
      final builtIndex = (any!.widget as QueueTrackRow).index;
      final centred = RenderAbstractViewport.of(box)
          .getOffsetToReveal(box, 0.5);
      position.jumpTo(
        (centred.offset + (index - builtIndex) * box.size.height).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    }
    // Frame time, so tests on fake time settle too.
    if (now - started >= _settleWindow) return;
    SchedulerBinding.instance
      ..addPostFrameCallback((timeStamp) => _pass(index, started, timeStamp))
      ..scheduleFrame();
  }
}
