import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/playback_anomaly_recorder.dart';

void main() {
  final base = DateTime.utc(2026, 10, 22);
  var clock = base;
  late List<String> logs;
  late PlaybackAnomalyRecorder recorder;
  final entryA = Object();
  final entryB = Object();

  setUp(() {
    clock = base;
    logs = <String>[];
    recorder = PlaybackAnomalyRecorder(
      now: () => clock,
      log: logs.add,
      header: () => <String, Object?>{'platform': 'test', 'index': 1},
    );
  });

  void at(int ms) => clock = base.add(Duration(milliseconds: ms));

  void sample(
    int atMs,
    int positionMs, {
    Object? entry,
    String song = 'secret-song-1',
    int? durationMs = 200000,
    bool repeatOne = false,
    bool playing = true,
    bool seeking = false,
  }) {
    at(atMs);
    recorder.observePosition(
      position: Duration(milliseconds: positionMs),
      entryKey: entry ?? entryA,
      songId: song,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      repeatOne: repeatOne,
      playing: playing,
      seeking: seeking,
    );
  }

  void sample0(PlaybackAnomalyRecorder r, int atMs, int positionMs) {
    at(atMs);
    r.observePosition(
      position: Duration(milliseconds: positionMs),
      entryKey: entryA,
      songId: 's',
      duration: const Duration(seconds: 200),
      repeatOne: false,
      playing: true,
    );
  }

  List<String> lines(String log) => const LineSplitter().convert(log);
  Map<String, Object?> header(String log) =>
      jsonDecode(lines(log).first.substring('[PLAYBACK_ANOMALY] '.length))
          as Map<String, Object?>;

  group('backwardJump', () {
    test('a confirmed 8 s step back records the last 30 s of events', () {
      at(0);
      recorder.event('pb', {'state': 'old'});
      at(20000);
      recorder.event('pb', {'state': 'ready'});
      for (var s = 25; s <= 30; s++) {
        sample(s * 1000, 55000 + (s - 25) * 1000);
      }
      sample(30200, 52000);
      expect(logs, isEmpty, reason: 'one sample is not enough');
      sample(30600, 52400);

      expect(logs, hasLength(1));
      final head = header(logs.single);
      expect(head['kind'], 'backwardJump');
      expect(head['fromMs'], 60000);
      expect(head['toMs'], 52000);
      expect(head['sameEntry'], isTrue);
      expect(head['platform'], 'test');
      final text = logs.single;
      expect(text, contains('"state":"ready"'));
      expect(text, isNot(contains('"state":"old"')));
      expect(recorder.recent, hasLength(1));
      expect(recorder.recent.single['kind'], 'backwardJump');
    });

    test('a 1.9 s step back is a native correction, not a record', () {
      sample(0, 60000);
      sample(200, 58100);
      sample(600, 58500);
      expect(logs, isEmpty);
    });

    test('a seek between the samples explains the jump', () {
      sample(0, 60000);
      recorder.expect('seek', {'targetMs': 52000});
      sample(200, 52000);
      sample(600, 52400);
      expect(logs, isEmpty);
    });

    test('a seek one second before the jump still explains it', () {
      sample(0, 60000);
      recorder.expect('seek', {'targetMs': 52000});
      sample(500, 60500);
      sample(1000, 52000);
      sample(1400, 52400);
      expect(logs, isEmpty);
    });

    test('samples while a seek is pending are ignored', () {
      sample(0, 60000);
      sample(200, 30000, seeking: true);
      sample(600, 30400, seeking: true);
      sample(800, 60200);
      expect(logs, isEmpty);
    });

    test('a recovery event does not explain a landing behind its target', () {
      sample(0, 60000);
      recorder.event('recovery', {'targetMs': 60000});
      sample(200, 52000);
      sample(600, 52400);

      expect(logs, hasLength(1));
      expect(logs.single, contains('"e":"recovery"'));
      expect(logs.single, contains('"targetMs":60000'));
    });

    test('a transient zero that recovers is dropped', () {
      sample(0, 60000);
      sample(200, 0);
      sample(600, 60400);
      expect(logs, isEmpty);
    });

    test('a transient zero followed by an entry change is dropped', () {
      sample(0, 60000);
      sample(200, 0);
      sample(600, 500, entry: entryB, song: 'secret-song-2');
      expect(logs, isEmpty);
    });

    test('paused or not-playing samples never record', () {
      sample(0, 60000);
      sample(200, 52000, playing: false);
      sample(600, 52000, playing: false);
      expect(logs, isEmpty);
    });

    test('an unknown duration still records the jump', () {
      sample(0, 196000, durationMs: null);
      sample(200, 400, durationMs: null);
      sample(600, 800, durationMs: null);

      expect(logs, hasLength(1));
      expect(header(logs.single)['kind'], 'backwardJump');
    });
  });

  group('backwardJump late and stale', () {
    test('a late confirming sample still records the jump', () {
      sample(0, 60000);
      sample(200, 52000);
      sample(5200, 57000);

      expect(logs, hasLength(1));
      expect(header(logs.single)['kind'], 'backwardJump');
    });

    test('a swapped queue entry for the same song keeps the baseline', () {
      sample(0, 60000);
      sample(1000, 61000, entry: entryB);
      sample(6000, 56000, entry: entryB);
      sample(6400, 56400, entry: entryB);

      expect(logs, hasLength(1));
      final head = header(logs.single);
      expect(head['kind'], 'backwardJump');
      expect(head['sameEntry'], isTrue);
    });

    test('a different song is never a backward jump', () {
      sample(0, 60000);
      sample(200, 52000, song: 'secret-song-2');
      sample(600, 52400, song: 'secret-song-2');
      expect(logs, isEmpty);
    });

    test('a baseline older than 10 s is stale', () {
      sample(0, 199000);
      sample(60000, 100, playing: true);
      sample(60400, 500);
      expect(logs, isEmpty);
    });
  });

  group('replayNearEnd', () {
    test('the same entry replaying from the start is recorded', () {
      sample(0, 196000);
      sample(200, 400);
      sample(600, 800);

      expect(logs, hasLength(1));
      final head = header(logs.single);
      expect(head['kind'], 'replayNearEnd');
      expect(head['sameEntry'], isTrue);
    });

    test('Repeat One and a loop expectation suppress it', () {
      sample(0, 196000, repeatOne: true);
      sample(200, 400, repeatOne: true);
      sample(600, 800, repeatOne: true);
      expect(logs.where((l) => l.contains('replayNearEnd')), isEmpty);

      recorder.expect('loop');
      sample(1000, 196000);
      recorder.expect('loop');
      sample(1200, 400);
      sample(1600, 800);
      expect(logs.where((l) => l.contains('replayNearEnd')), isEmpty);
    });

    test('another entry holding the same song replaying is recorded', () {
      sample(0, 197000);
      sample(2000, 500, entry: entryB);
      sample(2400, 900, entry: entryB);

      expect(logs, hasLength(1));
      final head = header(logs.single);
      expect(head['kind'], 'replayNearEnd');
      expect(head['sameEntry'], isFalse);
    });

    test('a navigation expectation suppresses the entry change', () {
      sample(0, 197000);
      recorder.expect('nav');
      sample(2000, 500, entry: entryB);
      sample(2400, 900, entry: entryB);
      expect(logs, isEmpty);
    });

    test('a different song is the normal advance', () {
      sample(0, 197000);
      sample(2000, 500, entry: entryB, song: 'secret-song-2');
      sample(2400, 900, entry: entryB, song: 'secret-song-2');
      expect(logs, isEmpty);
    });

    test('a restartCompleted event does not suppress it', () {
      sample(0, 197000);
      recorder.event('restartCompleted');
      sample(2000, 500, entry: entryB);
      sample(2400, 900, entry: entryB);

      expect(logs, hasLength(1));
      expect(logs.single, contains('"e":"restartCompleted"'));
    });

    test('Play after the queue completed minutes later is not recorded', () {
      sample(0, 199000);
      sample(200, 199800, playing: false);
      sample(60000, 100);
      sample(60400, 500);
      expect(logs, isEmpty);
    });

    test('a restart within seconds of the end is recorded', () {
      sample(0, 199000);
      sample(200, 199800, playing: false);
      sample(3000, 100);
      sample(3400, 500);

      expect(logs, hasLength(1));
      expect(header(logs.single)['kind'], 'replayNearEnd');
    });

    test('a replay 30 s after the end is a user action', () {
      sample(0, 197000);
      sample(30000, 500, entry: entryB);
      sample(30400, 900, entry: entryB);
      expect(logs, isEmpty);
    });

    test('an unknown duration skips the near-end rule', () {
      sample(0, 197000, durationMs: null);
      sample(2000, 500, entry: entryB, durationMs: null);
      sample(2400, 900, entry: entryB, durationMs: null);

      // Only the backward jump of the same song is left.
      expect(logs, hasLength(1));
      expect(header(logs.single)['kind'], 'backwardJump');
      expect(header(logs.single)['sameEntry'], isFalse);
    });
  });

  group('sink', () {
    test('the default sink prints every line with debugPrint', () {
      final printed = <String?>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => printed.add(message);
      addTearDown(() => debugPrint = original);
      final plain = PlaybackAnomalyRecorder(now: () => clock);
      sample0(plain, 0, 60000);
      sample0(plain, 200, 52000);
      sample0(plain, 600, 52400);

      expect(printed, isNotEmpty);
      expect(printed.every((l) => l!.startsWith('[PLAYBACK_ANOMALY]')), isTrue);
      expect(printed.first, contains('"kind":"backwardJump"'));
    });
  });

  group('limits and content', () {
    void jump(int atMs, String song) {
      sample(atMs, 60000, song: song);
      sample(atMs + 200, 50000, song: song);
      sample(atMs + 600, 50400, song: song);
    }

    test('one record per kind per song', () {
      jump(0, 'a');
      jump(5000, 'a');
      expect(logs, hasLength(1));
      jump(10000, 'b');
      expect(logs, hasLength(2));
    });

    test('at most 20 records per session, and recent keeps 5', () {
      for (var i = 0; i < 25; i++) {
        jump(i * 5000, 'song-$i');
      }
      expect(logs, hasLength(20));
      expect(recorder.recent, hasLength(5));
      // Only the newest record carries its events.
      expect(recorder.recent.last, contains('events'));
      expect(recorder.recent.first, isNot(contains('events')));
      expect(recorder.recent.first['eventCount'], isA<int>());
    });

    test('the ring holds at most 400 rows', () {
      sample(0, 60000);
      at(100);
      for (var i = 0; i < 600; i++) {
        recorder.event('pb', {'i': i});
      }
      sample(200, 50000);
      sample(600, 50400);

      // header + at most 400 rows
      expect(lines(logs.single).length, lessThanOrEqualTo(401));
    });

    test('records carry no song id, url or title, and stay short', () {
      sample(0, 60000, song: 'secret-song-1');
      recorder.event('pb', {'state': 'ready', 'index': 1});
      sample(200, 50000, song: 'secret-song-1');
      sample(600, 50400, song: 'secret-song-1');

      final log = logs.single;
      expect(log, isNot(contains('secret-song-1')));
      expect(log, isNot(contains('http')));
      for (final line in lines(log)) {
        expect(line, startsWith('[PLAYBACK_ANOMALY]'));
        expect(line.length, lessThan(1024));
      }
    });
  });
}
