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
      await Future.wait(replacements.take(99))
          .timeout(const Duration(seconds: 1));
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

  test(
    'edits wait in order behind a replacement and are never dropped',
    () async {
      final lane = NavisSupersedingLane();
      final release = Completer<void>();
      final order = <String>[];
      final fill = lane.run((token) async {
        await release.future;
        token.checkCancelled();
        order.add('fill');
      });
      final edits = <Future<void>>[
        for (final name in ['add', 'remove', 'reorder'])
          lane.enqueue((_) async => order.add(name)),
      ];
      expect(lane.pendingCount, 3);
      release.complete();
      await fill;
      await Future.wait(edits);
      expect(order, ['fill', 'add', 'remove', 'reorder']);
    },
  );

  test('a replacement cancels waiting edits', () async {
    final lane = NavisSupersedingLane();
    final release = Completer<void>();
    final order = <String>[];
    unawaited(lane.run((_) async => release.future));
    final edit = lane.enqueue((_) async => order.add('edit'));
    final replace = lane.run((_) async => order.add('replace'));
    release.complete();
    await edit;
    await replace;
    expect(order, ['replace']);
  });

  test('navigation cancels replacements but lets edits finish first', () async {
    final lane = NavisSupersedingLane();
    final release = Completer<void>();
    final order = <String>[];
    unawaited(
      lane.enqueue((_) async {
        await release.future;
        order.add('active edit');
      }),
    );
    final waitingEdit = lane.enqueue((_) async => order.add('edit'));
    final replace = lane.run((token) async {
      token.checkCancelled();
      order.add('replace');
    });
    // `run` supersedes everything, including edits; navigation does not.
    final edit = lane.enqueue((_) async => order.add('later edit'));
    final navigate = lane.navigate((_) async => order.add('navigate'));
    release.complete();
    await Future.wait([waitingEdit, replace, edit, navigate]);
    expect(order, ['active edit', 'later edit', 'navigate']);
  });

  test('idle work runs only on an empty lane and yields to commands', () async {
    final lane = NavisSupersedingLane();
    final release = Completer<void>();
    final order = <String>[];
    unawaited(lane.enqueue((_) async => release.future));
    expect(lane.tryRunIdle((_) async => order.add('too early')), isNull);
    release.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final idleEntered = Completer<void>();
    final idleRelease = Completer<void>();
    final idle = lane.tryRunIdle((token) async {
      idleEntered.complete();
      await idleRelease.future;
      token.checkCancelled();
      order.add('idle');
    });
    expect(idle, isNotNull);
    await idleEntered.future;
    final edit = lane.enqueue((_) async => order.add('edit'));
    idleRelease.complete();
    await Future.wait([idle!, edit]);
    expect(order, ['edit']);
  });

  test(
    'a fill keeps commands made before it and yields to navigation',
    () async {
      final lane = NavisSupersedingLane();
      final order = <String>[];
      final release = Completer<void>();
      final first = lane.run((_) => release.future);

      final navigation = lane.navigate((_) async => order.add('navigate'));
      final edit = lane.enqueue((_) async => order.add('edit'));
      // Submitting the fill cancels neither.
      final fill = lane.fill((token) async {
        token.checkCancelled();
        order.add('fill');
      });
      final laterEdit = lane.enqueue((_) async => order.add('later edit'));
      release.complete();
      await Future.wait([first, navigation, edit, fill, laterEdit]);
      expect(order, ['navigate', 'edit', 'fill', 'later edit']);

      // A navigation made while a fill waits cancels it.
      order.clear();
      final hold = Completer<void>();
      final busy = lane.enqueue((_) => hold.future);
      final waitingFill = lane.fill((_) async => order.add('fill'));
      final skip = lane.navigate((_) async => order.add('navigate'));
      hold.complete();
      await Future.wait([busy, waitingFill, skip]);
      expect(order, ['navigate']);
    },
  );

  test('the lane reports when it drains', () async {
    final lane = NavisSupersedingLane();
    var drained = 0;
    lane.onDrained = () => drained++;
    await lane.enqueue((_) async {});
    await Future<void>.delayed(Duration.zero);
    expect(drained, 1);
    expect(lane.isIdle, isTrue);
  });
}
