import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/playback_transport_trace.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/constants.dart';

void main() {
  test(
    'keeps the newest entries in order with increasing sequence numbers',
    () {
      final trace = PlaybackTransportTrace(enabled: true, capacity: 3);
      for (var i = 0; i < 5; i++) {
        trace.record('event', () => <String, Object?>{'i': i});
      }
      final entries = trace.entries;
      expect(entries.map((e) => e['i']), <Object?>[2, 3, 4]);
      expect(entries.map((e) => e['seq']), <Object?>[3, 4, 5]);
      expect(entries.first['kind'], 'event');
      expect(entries.first['atMs'], isA<int>());
    },
  );

  test('records nothing and skips the data callback when disabled', () {
    final trace = PlaybackTransportTrace(enabled: false);
    var evaluated = false;
    trace.record('event', () {
      evaluated = true;
      return <String, Object?>{};
    });
    expect(trace.entries, isEmpty);
    expect(evaluated, isFalse);
  });

  test('is disabled in builds without NAVIS_SYNC_DIAGNOSTICS', () {
    final trace = PlaybackTransportTrace();
    trace.record('event', () => <String, Object?>{'x': 1});
    expect(trace.enabled, isFalse);
    expect(trace.entries, isEmpty);
  });

  test('an enabled trace keeps a loadFailure entry', () {
    final trace = PlaybackTransportTrace(enabled: true);
    trace.record('loadFailure', () => <String, Object?>{'songId': 's1'});
    expect(trace.entries.single['kind'], 'loadFailure');
  });

  test('the dev-channel tile and the trace share one predicate', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(devChannelBuildProvider), AppConstants.isDevChannel);
    expect(
      PlaybackTransportTrace().enabled,
      AppConstants.isDevChannel ||
          const bool.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS'),
    );
  });
}
