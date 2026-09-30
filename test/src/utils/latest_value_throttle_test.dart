import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/latest_value_throttle.dart';

void main() {
  test('publishes the first value, holds bursts, flushes the latest', () {
    fakeAsync((async) {
      final published = <int>[];
      final clock = async.getClock(DateTime(2026));
      final throttle = LatestValueThrottle<int>(
        interval: const Duration(milliseconds: 250),
        onPublish: published.add,
        now: clock.now,
      );

      throttle.add(1);
      throttle.add(2);
      throttle.add(3);
      expect(published, <int>[1]);

      async.elapse(const Duration(milliseconds: 250));
      expect(published, <int>[1, 3]);

      async.elapse(const Duration(seconds: 1));
      throttle.add(4);
      expect(published, <int>[1, 3, 4]);
    });
  });

  test('urgent values publish immediately and replace a held value', () {
    fakeAsync((async) {
      final published = <int>[];
      final clock = async.getClock(DateTime(2026));
      final throttle = LatestValueThrottle<int>(
        interval: const Duration(milliseconds: 250),
        onPublish: published.add,
        now: clock.now,
      );

      throttle.add(1);
      throttle.add(2);
      throttle.add(3, urgent: true);
      async.elapse(const Duration(seconds: 1));
      expect(published, <int>[1, 3]);
    });
  });

  test('close drops a held value', () {
    fakeAsync((async) {
      final published = <int>[];
      final clock = async.getClock(DateTime(2026));
      final throttle = LatestValueThrottle<int>(
        interval: const Duration(milliseconds: 250),
        onPublish: published.add,
        now: clock.now,
      );

      throttle.add(1);
      throttle.add(2);
      throttle.close();
      async.elapse(const Duration(seconds: 1));
      throttle.add(3);
      expect(published, <int>[1]);
    });
  });
}
