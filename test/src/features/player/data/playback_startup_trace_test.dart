import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/playback_startup_trace.dart';

void main() {
  test('startup trace exports ordered stages without media identity', () {
    final trace = PlaybackStartupTrace(
      attempt: 7,
      songId: 'ext-deezer-private-id',
      isExternal: true,
    );
    trace.mark('provisionalPersistenceComplete');
    trace.mark('selectedSourceApplyComplete');
    trace.sourceKind = 'directStream';
    trace.observePosition(Duration.zero);
    trace.observePosition(Duration.zero);
    trace.observePosition(const Duration(milliseconds: 200));
    trace.observePosition(const Duration(milliseconds: 400));

    final result = trace.toDiagnostics();
    final events = result['events']! as List<Map<String, Object>>;
    expect(result['attempt'], 7);
    expect(result['external'], isTrue);
    expect(result['sourceKind'], 'directStream');
    expect(trace.sourceApplied, isTrue);
    expect(
      events.map((event) => event['stage']),
      <String>[
        'selection',
        'provisionalPersistenceComplete',
        'selectedSourceApplyComplete',
        'firstAdvancingPosition',
      ],
    );
    expect(events.map((event) => event['elapsedMs']), everyElement(isA<int>()));
    expect(result.toString(), isNot(contains('ext-deezer-private-id')));
  });
}
