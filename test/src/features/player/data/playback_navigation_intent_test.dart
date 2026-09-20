import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/playback_navigation_intent.dart';

void main() {
  test(
    'rapid relative presses accumulate without confirming intermediate songs',
    () {
      final intent = PlaybackNavigationIntent();
      const order = <int>[0, 1, 2, 3, 4];

      final first = intent.relative(
        forward: true,
        confirmedIndex: 1,
        confirmedPosition: Duration.zero,
        effectiveOrder: order,
      );
      final second = intent.relative(
        forward: true,
        confirmedIndex: 1,
        confirmedPosition: Duration.zero,
        effectiveOrder: order,
      );
      final last = intent.relative(
        forward: false,
        confirmedIndex: 1,
        confirmedPosition: Duration.zero,
        effectiveOrder: order,
      );

      expect(<int?>[first.index, second.index, last.index], <int>[2, 3, 2]);
      expect(intent.isCurrent(first.revision), isFalse);
      intent.confirm(first.revision);
      expect(intent.isPending, isTrue);
      intent.confirm(last.revision);
      expect(intent.isPending, isFalse);
    },
  );

  test('previous restart applies only before a pending navigation', () {
    final intent = PlaybackNavigationIntent();
    const order = <int>[0, 1, 2];
    final restart = intent.relative(
      forward: false,
      confirmedIndex: 2,
      confirmedPosition: const Duration(seconds: 4),
      effectiveOrder: order,
    );
    final previous = intent.relative(
      forward: false,
      confirmedIndex: 2,
      confirmedPosition: const Duration(seconds: 4),
      effectiveOrder: order,
    );
    expect(restart.outcome, PlaybackNavigationOutcome.restart);
    expect(restart.index, 2);
    expect(previous.outcome, PlaybackNavigationOutcome.previous);
    expect(previous.index, 1);
  });

  test(
    'shuffle uses effective order and explicit selection replaces the target',
    () {
      final intent = PlaybackNavigationIntent();
      const order = <int>[3, 0, 2, 1];
      final first = intent.relative(
        forward: true,
        confirmedIndex: 3,
        confirmedPosition: Duration.zero,
        effectiveOrder: order,
      );
      intent.select(2);
      final next = intent.relative(
        forward: true,
        confirmedIndex: 3,
        confirmedPosition: Duration.zero,
        effectiveOrder: order,
      );
      expect(first.index, 0);
      expect(next.index, 1);
      intent.reset();
      expect(intent.isCurrent(next.revision), isFalse);
    },
  );

  test('out-of-bounds command does not alter the desired target', () {
    final intent = PlaybackNavigationIntent();
    const order = <int>[0, 1, 2];
    intent.select(2);
    final unavailable = intent.relative(
      forward: true,
      confirmedIndex: 0,
      confirmedPosition: Duration.zero,
      effectiveOrder: order,
    );
    expect(unavailable.outcome, PlaybackNavigationOutcome.unavailableNext);
    expect(unavailable.canApply, isFalse);
    expect(intent.desiredIndex, 2);
  });

  test('one hundred presses keep only the last desired queue entry', () {
    final intent = PlaybackNavigationIntent();
    final order = List<int>.generate(20, (index) => index);
    for (var press = 0; press < 100; press++) {
      intent.relative(
        forward: true,
        confirmedIndex: 0,
        confirmedPosition: Duration.zero,
        effectiveOrder: order,
      );
    }
    expect(intent.desiredIndex, 19);
    expect(intent.isPending, isTrue);
    for (var press = 0; press < 100; press++) {
      intent.relative(
        forward: false,
        confirmedIndex: 0,
        confirmedPosition: Duration.zero,
        effectiveOrder: order,
      );
    }
    expect(intent.desiredIndex, 0);
  });

  test('repeat all wraps in the effective order', () {
    final intent = PlaybackNavigationIntent();
    final next = intent.relative(
      forward: true,
      confirmedIndex: 2,
      confirmedPosition: Duration.zero,
      effectiveOrder: const <int>[1, 0, 2],
      loopAll: true,
    );
    expect(next.index, 1);
  });
}
