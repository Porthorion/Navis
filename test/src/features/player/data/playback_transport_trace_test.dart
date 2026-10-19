import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/playback_transport_trace.dart';

void main() {
  test('keeps the newest entries in order with increasing sequence numbers', () {
    final trace = PlaybackTransportTrace(enabled: true, capacity: 3);
    for (var i = 0; i < 5; i++) {
      trace.record('event', () => <String, Object?>{'i': i});
    }
    final entries = trace.entries;
    expect(entries.map((e) => e['i']), <Object?>[2, 3, 4]);
    expect(entries.map((e) => e['seq']), <Object?>[3, 4, 5]);
    expect(entries.first['kind'], 'event');
    expect(entries.first['atMs'], isA<int>());
  });

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
}
