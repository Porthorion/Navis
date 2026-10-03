import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/deferred_seek.dart';

void main() {
  for (final durationFirst in [true, false]) {
    test(
      'initial seek survives readiness order durationFirst=$durationFirst',
      () async {
        var opened = false;
        var durationKnown = false;
        final applied = <Duration>[];
        final seek = DeferredSeek(
          isReady: () => opened && durationKnown,
          apply: (position) async => applied.add(position),
        )..beginLoad(const Duration(seconds: 90));
        if (durationFirst) {
          durationKnown = true;
        } else {
          opened = true;
        }
        await seek.flush();
        expect(applied, isEmpty);
        opened = durationKnown = true;
        await seek.flush();
        expect(applied, [const Duration(seconds: 90)]);
        expect(seek.isPending, isFalse);
      },
    );
  }

  test(
    'latest seek, including zero, replaces a pending initial position',
    () async {
      final applied = <Duration>[];
      final seek = DeferredSeek(
        isReady: () => true,
        apply: (position) async => applied.add(position),
      )..beginLoad(const Duration(seconds: 90));
      seek.request(Duration.zero);
      await seek.flush();
      expect(applied, [Duration.zero]);
    },
  );

  test('old completion cannot clear a new source position', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final applied = <Duration>[];
    final seek = DeferredSeek(
      isReady: () => true,
      apply: (position) async {
        applied.add(position);
        if (applied.length == 1) {
          entered.complete();
          await gate.future;
        }
      },
    )..beginLoad(const Duration(seconds: 90));
    final first = seek.flush();
    await entered.future;
    seek.beginLoad(const Duration(seconds: 20));
    gate.complete();
    await first;
    expect(applied, [const Duration(seconds: 90), const Duration(seconds: 20)]);
    expect(seek.isPending, isFalse);
  });

  test(
    'failed application keeps its position for a later readiness event',
    () async {
      var fail = true;
      final seek = DeferredSeek(
        isReady: () => true,
        apply: (_) async {
          if (fail) throw StateError('native seek rejected');
        },
      )..beginLoad(const Duration(seconds: 90));
      await expectLater(seek.flush(), throwsStateError);
      expect(seek.isPending, isTrue);
      fail = false;
      await seek.flush();
      expect(seek.isPending, isFalse);
    },
  );
}
