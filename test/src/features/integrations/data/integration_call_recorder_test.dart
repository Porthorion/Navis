import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

void main() {
  IntegrationCallRecorder newRecorder({int calls = 200, int spans = 100}) =>
      IntegrationCallRecorder(
        callCapacity: calls,
        spanCapacity: spans,
        now: () => DateTime.utc(2026, 10, 4, 12),
        logCalls: false,
      );

  void record(
    IntegrationCallRecorder recorder, {
    IntegrationService service = IntegrationService.lastFm,
    String url = 'https://ws.audioscrobbler.com/2.0/',
    IntegrationCallOutcome outcome = IntegrationCallOutcome.ok,
    int ms = 10,
    int? status = 200,
  }) {
    recorder.recordCall(
      service: service,
      method: 'get',
      uri: Uri.parse(url),
      duration: Duration(milliseconds: ms),
      outcome: outcome,
      statusCode: status,
    );
  }

  test('records service, method, path, status, duration and outcome', () {
    final recorder = newRecorder();
    record(recorder, url: 'https://lrclib.net/api/get', ms: 42);

    final call = recorder.recentCalls().single;
    expect(call.service, IntegrationService.lastFm);
    expect(call.method, 'GET');
    expect(call.path, '/api/get');
    expect(call.statusCode, 200);
    expect(call.durationMs, 42);
    expect(call.outcome, IntegrationCallOutcome.ok);
    expect(call.at, DateTime.utc(2026, 10, 4, 12));
  });

  test('keeps the newest 200 calls by default', () {
    final recorder = IntegrationCallRecorder(logCalls: false);
    for (var i = 0; i < 250; i++) {
      record(recorder, url: 'https://lrclib.net/call/$i');
    }
    final calls = recorder.recentCalls();
    expect(calls, hasLength(200));
    expect(calls.first.path, '/call/50');
    expect(calls.last.path, '/call/249');
    expect(recorder.recentCalls(limit: 3).map((c) => c.path), [
      '/call/247',
      '/call/248',
      '/call/249',
    ]);
  });

  test('counters separate sent, blocked and failed calls', () {
    final recorder = newRecorder();
    record(recorder, ms: 100);
    record(recorder, ms: 50, outcome: IntegrationCallOutcome.error);
    record(recorder, ms: 0, outcome: IntegrationCallOutcome.blocked);
    record(recorder, service: IntegrationService.lrclib, ms: 7);

    final lastFm = recorder.countersFor(IntegrationService.lastFm);
    expect(lastFm.requests, 2, reason: 'blocked calls never left the device');
    expect(lastFm.blocked, 1);
    expect(lastFm.errors, 1);
    expect(lastFm.totalMs, 150);
    expect(recorder.countersFor(IntegrationService.lrclib).requests, 1);
    expect(recorder.countersFor(IntegrationService.deezer).requests, 0);
  });

  test('keeps the newest spans and copies their counts', () {
    final recorder = newRecorder(spans: 2);
    final counts = <String, int>{'tracks': 5};
    recorder.span('a', counts, const Duration(milliseconds: 1));
    counts['tracks'] = 99;
    recorder.span('b', {'tracks': 6}, const Duration(milliseconds: 2));
    recorder.span('c', {'tracks': 7}, const Duration(milliseconds: 3));

    final spans = recorder.recentSpans();
    expect(spans.map((s) => s.name), ['b', 'c']);
    expect(spans.last.counts, {'tracks': 7});
    expect(spans.last.durationMs, 3);
  });

  test(
    'timeSpan records the elapsed time and the counts of the result',
    () async {
      final recorder = newRecorder();
      final result = await recorder.timeSpan<List<int>>(
        'work',
        () async => <int>[1, 2, 3],
        counts: (items) => {'items': items.length},
      );
      expect(result, [1, 2, 3]);
      final span = recorder.recentSpans().single;
      expect(span.name, 'work');
      expect(span.counts, {'items': 3});
    },
  );

  test('toJson caps calls at 100 and spans at 50 by default', () {
    final recorder = newRecorder();
    for (var i = 0; i < 150; i++) {
      record(recorder, url: 'https://lrclib.net/call/$i');
      recorder.span('s$i', const {}, Duration.zero);
    }
    final json = recorder.toJson();
    expect(json['calls']! as List, hasLength(100));
    expect(json['spans']! as List, hasLength(50));
    final counters = json['counters']! as Map<String, Object?>;
    expect(counters.keys, containsAll(<String>['lastfm', 'deezer', 'radio']));
    expect(
      (counters['lastfm']! as Map<String, Object?>)['requests'],
      150,
      reason: 'counters cover every call, not just the retained ones',
    );
  });

  test('clear empties calls, spans and counters', () {
    final recorder = newRecorder();
    record(recorder);
    recorder.span('a', const {}, Duration.zero);
    recorder.clear();
    expect(recorder.recentCalls(), isEmpty);
    expect(recorder.recentSpans(), isEmpty);
    expect(recorder.countersFor(IntegrationService.lastFm).requests, 0);
  });

  group('redaction', () {
    const secret = 'SUPERSECRETKEY123';

    test('a query string never reaches any recorded field or the JSON', () {
      final recorder = newRecorder();
      record(
        recorder,
        url:
            'https://ws.audioscrobbler.com/2.0/?method=track.getSimilar'
            '&api_key=$secret&artist=Someone#frag-$secret',
      );
      record(
        recorder,
        service: IntegrationService.listenBrainz,
        url: 'https://api.listenbrainz.org/1/user/me/playlists?token=$secret',
        outcome: IntegrationCallOutcome.blocked,
        status: null,
      );
      final call = recorder.recentCalls().first;
      expect(call.path, '/2.0/');
      final everything = [
        for (final c in recorder.recentCalls()) jsonEncode(c.toJson()),
        jsonEncode(recorder.toJson()),
      ].join();
      expect(everything, isNot(contains(secret)));
      expect(everything, isNot(contains('api_key')));
      expect(everything, isNot(contains('method=')));
      expect(everything, isNot(contains('frag')));
    });

    test('the host is not recorded either', () {
      final recorder = newRecorder();
      record(recorder, url: 'https://user:pass@radio.private.example/np/x');
      final json = jsonEncode(recorder.toJson());
      expect(json, isNot(contains('radio.private.example')));
      expect(json, isNot(contains('pass')));
    });

    test('an unexpectedly long path is capped', () {
      final recorder = newRecorder();
      record(recorder, url: 'https://lrclib.net/${'a' * 500}');
      expect(recorder.recentCalls().single.path.length, lessThanOrEqualTo(200));
    });
  });
}
