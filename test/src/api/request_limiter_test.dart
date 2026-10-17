import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/request_limiter.dart';

void main() {
  for (final background in [false, true]) {
    test('cancel after dispatch returns the start budget: $background', () {
      fakeAsync((async) {
        final limiter = RequestLimiter(
          elapsed: () => async.elapsed,
          maxPerWindow: 1,
          maxBackgroundPerWindow: 1,
          maxInFlight: 1,
        );
        final token = CancelToken();
        var cancelled = false;
        var ranCancelled = false;
        var ranLive = false;
        unawaited(
          limiter
              .run(
                () async {
                  ranCancelled = true;
                },
                background: background,
                cancelToken: token,
              )
              .then<void>(
                (_) => fail('must cancel'),
                onError: (Object error) {
                  expect(error, isA<DioException>());
                  cancelled = true;
                },
              ),
        );
        token.cancel();
        unawaited(
          limiter.run(() async {
            ranLive = true;
          }, background: background),
        );
        async.flushMicrotasks();
        expect(cancelled, isTrue);
        expect(ranCancelled, isFalse);
        expect(ranLive, isTrue);
        expect(limiter.inFlight, 0);
      });
    });
  }

  test('cancellation while paused settles without waiting for the pause', () {
    fakeAsync((async) {
      final limiter = RequestLimiter(elapsed: () => async.elapsed);
      limiter.pauseStarts(const Duration(seconds: 80));
      final token = CancelToken();
      var cancelled = false;
      unawaited(
        limiter
            .run(() async => fail('must not start'), cancelToken: token)
            .then<void>(
              (_) => fail('must cancel'),
              onError: (Object error) {
                expect(error, isA<DioException>());
                cancelled = true;
              },
            ),
      );
      token.cancel();
      async.flushMicrotasks();
      expect(cancelled, isTrue);
      expect(async.elapsed, Duration.zero);
      expect(limiter.inFlight, 0);
    });
  });

  test('starts at most 5 requests per second', () {
    fakeAsync((async) {
      final limiter = RequestLimiter(elapsed: () => async.elapsed);
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

  test('waits whole milliseconds, never a sub-millisecond spin', () {
    // Dart runs a sub-millisecond timer after 0 ms, so a wait shorter than
    // the time left in the window would fire early and reschedule in a loop.
    var now = Duration.zero;
    final waits = <Duration>[];
    final limiter = RequestLimiter(
      maxPerWindow: 1,
      elapsed: () => now,
      delay: (wait) {
        waits.add(wait);
        return Completer<void>().future;
      },
    );
    unawaited(limiter.run(() async {}));
    now = const Duration(microseconds: 999500);
    unawaited(limiter.run(() async {}));

    expect(waits, [const Duration(milliseconds: 1)]);
  });

  test('runs at most 4 requests at once', () {
    fakeAsync((async) {
      final limiter = RequestLimiter(elapsed: () => async.elapsed);
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
      final limiter = RequestLimiter(elapsed: () => async.elapsed);
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
      final limiter = RequestLimiter(elapsed: () => async.elapsed);
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

  group('priority', () {
    test('a waiting foreground request takes the next free slot', () {
      fakeAsync((async) {
        final limiter = RequestLimiter(
          elapsed: () => async.elapsed,
          maxInFlight: 1,
        );
        final started = <String>[];
        void queue(String name, {required bool background}) => unawaited(
          limiter.run(() async {
            started.add(name);
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }, background: background),
        );

        for (var i = 0; i < 4; i++) {
          queue('background $i', background: true);
        }
        async.flushMicrotasks();
        queue('foreground', background: false);

        async.elapse(const Duration(seconds: 2));
        expect(started, [
          'background 0',
          'foreground',
          'background 1',
          'background 2',
          'background 3',
        ]);
      });
    });

    test('a waiting foreground request takes the next start of the window', () {
      fakeAsync((async) {
        // Background may fill the window here, to test the order alone.
        final limiter = RequestLimiter(
          elapsed: () => async.elapsed,
          maxBackgroundPerWindow: 5,
        );
        final started = <String>[];
        for (var i = 0; i < 8; i++) {
          unawaited(
            limiter.run(() async {
              started.add('background $i');
            }, background: true),
          );
        }
        async.flushMicrotasks();
        expect(started, hasLength(5));
        unawaited(
          limiter.run(() async {
            started.add('foreground');
          }),
        );

        async.elapse(const Duration(seconds: 1));
        expect(started.sublist(5), [
          'foreground',
          'background 5',
          'background 6',
          'background 7',
        ]);
      });
    });

    test('background requests run whenever no foreground one waits', () {
      fakeAsync((async) {
        final limiter = RequestLimiter(
          elapsed: () => async.elapsed,
          maxInFlight: 1,
        );
        final started = <String>[];
        void queue(String name, {bool background = false}) => unawaited(
          limiter.run(() async {
            started.add(name);
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }, background: background),
        );
        for (var i = 0; i < 6; i++) {
          queue('background $i', background: true);
        }
        async.flushMicrotasks();
        queue('foreground 0');
        queue('foreground 1');
        async.elapse(const Duration(milliseconds: 100));
        expect(started, ['background 0', 'foreground 0']);
        queue('foreground 2');
        async.elapse(const Duration(milliseconds: 200));
        expect(started, [
          'background 0',
          'foreground 0',
          'foreground 1',
          'foreground 2',
        ]);
        async.elapse(const Duration(milliseconds: 100));
        expect(started.last, 'background 1');
        async.elapse(const Duration(seconds: 3));
        expect(started.skip(4), [for (var i = 1; i < 6; i++) 'background $i']);
        expect(limiter.inFlight, 0);
      });
    });
  });

  group('background rate', () {
    test('background starts at most 2 requests per second', () {
      fakeAsync((async) {
        final limiter = RequestLimiter(elapsed: () => async.elapsed);
        final starts = <Duration>[];
        for (var i = 0; i < 6; i++) {
          unawaited(
            limiter.run(() async {
              starts.add(async.elapsed);
            }, background: true),
          );
        }

        async.flushMicrotasks();
        expect(starts, hasLength(2));
        async.elapse(const Duration(milliseconds: 999));
        expect(starts, hasLength(2));
        async.elapse(const Duration(milliseconds: 1));
        expect(starts, hasLength(4));
        async.elapse(const Duration(seconds: 1));
        expect(starts, hasLength(6));
      });
    });

    test('foreground still uses the whole window beside background', () {
      fakeAsync((async) {
        final limiter = RequestLimiter(elapsed: () => async.elapsed);
        final started = <String>[];
        void queue(String name, {bool background = false}) => unawaited(
          limiter.run(() async {
            started.add(name);
          }, background: background),
        );
        for (var i = 0; i < 4; i++) {
          queue('background $i', background: true);
        }
        for (var i = 0; i < 4; i++) {
          queue('foreground $i');
        }

        async.flushMicrotasks();
        // Five in the second: two background, then three foreground.
        expect(started, [
          'background 0',
          'background 1',
          'foreground 0',
          'foreground 1',
          'foreground 2',
        ]);
        async.elapse(const Duration(seconds: 1));
        expect(started.sublist(5), [
          'foreground 3',
          'background 2',
          'background 3',
        ]);
      });
    });

    test('a foreground request does not wait for the background rate', () {
      fakeAsync((async) {
        final limiter = RequestLimiter(elapsed: () => async.elapsed);
        final starts = <String, Duration>{};
        void queue(String name, {bool background = false}) => unawaited(
          limiter.run(() async {
            starts[name] = async.elapsed;
          }, background: background),
        );

        queue('foreground 0');
        async.elapse(const Duration(milliseconds: 500));
        // Two background starts fill the background rate until 1.5 s.
        for (var i = 0; i < 3; i++) {
          queue('background $i', background: true);
        }
        async.elapse(const Duration(milliseconds: 100));
        // Two more fill the whole window, which frees up at 1 s.
        queue('foreground 1');
        queue('foreground 2');
        queue('foreground 3');

        async.elapse(const Duration(seconds: 2));
        expect(starts['foreground 3'], const Duration(seconds: 1));
        expect(starts['background 2'], const Duration(milliseconds: 1500));
      });
    });
  });

  test('a failing request frees its slot', () async {
    final limiter = RequestLimiter(maxInFlight: 1);

    await expectLater(
      limiter.run<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(limiter.inFlight, 0);
    expect(await limiter.run(() async => 'next'), 'next');
  });
}
