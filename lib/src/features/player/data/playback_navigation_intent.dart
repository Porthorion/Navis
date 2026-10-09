import 'package:flutter/foundation.dart';

enum PlaybackNavigationOutcome {
  next,
  previous,
  restart,
  unavailableNext,
  unavailablePrevious,
}

@immutable
class PlaybackNavigationDecision {
  const new({
    required this.revision,
    required this.index,
    required this.outcome,
  });

  final int revision;
  final int? index;
  final PlaybackNavigationOutcome outcome;

  bool get canApply =>
      outcome == PlaybackNavigationOutcome.next ||
      outcome == PlaybackNavigationOutcome.previous ||
      outcome == PlaybackNavigationOutcome.restart;
}

/// Converts bursts of relative commands into one desired queue entry.
///
/// The caller owns the queue and player. This class only records intent; it
/// never starts an intermediate song or assumes a backend seek has succeeded.
class PlaybackNavigationIntent {
  int _revision = 0;
  int? _desiredIndex;
  bool _pending = false;

  int get revision => _revision;
  int? get desiredIndex => _desiredIndex;
  bool get isPending => _pending;

  void reset() {
    _revision++;
    _desiredIndex = null;
    _pending = false;
  }

  PlaybackNavigationDecision select(int index) {
    _desiredIndex = index;
    _pending = true;
    return PlaybackNavigationDecision(
      revision: ++_revision,
      index: index,
      outcome: PlaybackNavigationOutcome.next,
    );
  }

  PlaybackNavigationDecision relative({
    required bool forward,
    required int? confirmedIndex,
    required Duration confirmedPosition,
    required List<int> effectiveOrder,
    bool loopAll = false,
  }) {
    final current = _pending ? _desiredIndex : confirmedIndex;
    final position = current == null ? -1 : effectiveOrder.indexOf(current);
    if (position < 0) {
      return PlaybackNavigationDecision(
        revision: _revision,
        index: current,
        outcome: forward
            ? PlaybackNavigationOutcome.unavailableNext
            : PlaybackNavigationOutcome.unavailablePrevious,
      );
    }

    if (!forward &&
        ((!_pending && confirmedPosition > const Duration(seconds: 3)) ||
            (position == 0 && (!loopAll || effectiveOrder.length == 1)))) {
      _desiredIndex = current;
      _pending = true;
      return PlaybackNavigationDecision(
        revision: ++_revision,
        index: current,
        outcome: PlaybackNavigationOutcome.restart,
      );
    }

    var nextPosition = position + (forward ? 1 : -1);
    if (loopAll && effectiveOrder.length > 1) {
      nextPosition %= effectiveOrder.length;
    }
    if (nextPosition < 0 || nextPosition >= effectiveOrder.length) {
      return PlaybackNavigationDecision(
        revision: _revision,
        index: current,
        outcome: forward
            ? PlaybackNavigationOutcome.unavailableNext
            : PlaybackNavigationOutcome.unavailablePrevious,
      );
    }

    _desiredIndex = effectiveOrder[nextPosition];
    _pending = true;
    return PlaybackNavigationDecision(
      revision: ++_revision,
      index: _desiredIndex,
      outcome: forward
          ? PlaybackNavigationOutcome.next
          : PlaybackNavigationOutcome.previous,
    );
  }

  bool isCurrent(int revision) => _revision == revision;

  void confirm(int revision) {
    if (isCurrent(revision)) _pending = false;
  }
}
