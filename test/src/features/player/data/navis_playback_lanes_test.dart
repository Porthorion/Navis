import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';

void main() {
  test(
    'rapid replacements retain one pending command and never overlap',
    () async {
      final lane = NavisSupersedingLane();
      final entered = Completer<void>();
      final release = Completer<void>();
      var active = 0;
      var maxActive = 0;
      final executed = <int>[];

      final first = lane.run((token) async {
        active++;
        maxActive = active;
        entered.complete();
        try {
          await release.future;
          token.checkCancelled();
        } finally {
          active--;
        }
      });
      await entered.future;

      final replacements = <Future<void>>[];
      for (var index = 0; index < 100; index++) {
        replacements.add(
          lane.run((token) async {
            token.checkCancelled();
            active++;
            if (active > maxActive) maxActive = active;
            executed.add(index);
            active--;
          }),
        );
        expect(lane.pendingCount, 1);
      }

      // Cancelled callers settle even while the old backend call is blocked.
      await first.timeout(const Duration(seconds: 1));
      await Future.wait(replacements.take(99)).timeout(
        const Duration(seconds: 1),
      );
      expect(executed, isEmpty);

      release.complete();
      await replacements.last.timeout(const Duration(seconds: 1));
      expect(executed, <int>[99]);
      expect(maxActive, 1);
      expect(lane.pendingCount, 0);
    },
  );

  test('a failed command does not poison the lane', () async {
    final lane = NavisSupersedingLane();
    await expectLater(
      lane.run((_) async => throw StateError('test failure')),
      throwsStateError,
    );

    var ran = false;
    await lane.run((_) async {
      ran = true;
    });
    expect(ran, isTrue);
  });
}
