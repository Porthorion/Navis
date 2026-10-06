import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_request_limiter.dart';

void main() {
  test('starts at most 5 requests per second', () {
    fakeAsync((async) {
      final limiter = DeezerRequestLimiter(elapsed: () => async.elapsed);
      final starts = <Duration>[];
      for (var i = 0; i < 12; i++) {
        unawaited(
          limiter.run(() async {
            starts.add(async.elapsed);
          }),
        );
      }

      async.flushMicrotasks();
      expect(starts, hasLength(5));
      async.elapse(const Duration(milliseconds: 999));
      expect(starts, hasLength(5));
      async.elapse(const Duration(milliseconds: 1));
      expect(starts, hasLength(10));
      async.elapse(const Duration(seconds: 1));
      expect(starts, hasLength(12));

      // No window of one second ever holds more than 5 starts.
      for (final start in starts) {
        final inWindow = starts.where(
          (other) =>
              other >= start && other < start + const Duration(seconds: 1),
        );
        expect(inWindow.length, lessThanOrEqualTo(5));
      }
    });
  });

  test('runs at most 4 requests at once', () {
    fakeAsync((async) {
      final limiter = DeezerRequestLimiter(elapsed: () => async.elapsed);
      var running = 0;
      var maxRunning = 0;
      var finished = 0;
      for (var i = 0; i < 10; i++) {
        unawaited(
          limiter.run(() async {
            running++;
            maxRunning = running > maxRunning ? running : maxRunning;
            await Future<void>.delayed(const Duration(seconds: 2));
            running--;
            finished++;
          }),
        );
      }

      async.flushMicrotasks();
      expect(running, 4);
      expect(limiter.inFlight, 4);
      async.elapse(const Duration(seconds: 2));
      expect(running, 4);
      async.elapse(const Duration(seconds: 10));
      expect(finished, 10);
      expect(maxRunning, 4);
      expect(limiter.inFlight, 0);
    });
  });

  test('a pause holds every new start, not the running ones', () {
    fakeAsync((async) {
      final limiter = DeezerRequestLimiter(elapsed: () => async.elapsed);
      final starts = <Duration>[];
      var running = 0;
      unawaited(
        limiter.run(() async {
          starts.add(async.elapsed);
          running++;
          await Future<void>.delayed(const Duration(seconds: 1));
          running--;
        }),
      );
      async.flushMicrotasks();
      expect(running, 1);

      limiter.pauseStarts(const Duration(seconds: 5));
      for (var i = 0; i < 3; i++) {
        unawaited(
          limiter.run(() async {
            starts.add(async.elapsed);
          }),
        );
      }
      async.flushMicrotasks();
      expect(starts, hasLength(1));

      // The running request finishes during the pause.
      async.elapse(const Duration(seconds: 1));
      expect(running, 0);
      expect(starts, hasLength(1));

      async.elapse(const Duration(milliseconds: 3999));
      expect(starts, hasLength(1));
      async.elapse(const Duration(milliseconds: 1));
      expect(starts, hasLength(4));
      expect(starts.skip(1), everyElement(const Duration(seconds: 5)));
    });
  });

  test('a later pause extends an earlier one, never shortens it', () {
    fakeAsync((async) {
      final limiter = DeezerRequestLimiter(elapsed: () => async.elapsed);
      final starts = <Duration>[];
      limiter.pauseStarts(const Duration(seconds: 5));
      async.elapse(const Duration(seconds: 2));
      limiter
        ..pauseStarts(const Duration(seconds: 5))
        ..pauseStarts(const Duration(seconds: 1));
      unawaited(
        limiter.run(() async {
          starts.add(async.elapsed);
        }),
      );

      async.elapse(const Duration(milliseconds: 4999));
      expect(starts, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(starts, [const Duration(seconds: 7)]);
    });
  });

  test('a failing request frees its slot', () async {
    final limiter = DeezerRequestLimiter(maxInFlight: 1);

    await expectLater(
      limiter.run<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(limiter.inFlight, 0);
    expect(await limiter.run(() async => 'next'), 'next');
  });
}
