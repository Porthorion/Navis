import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/replay_gain_boost.dart';

const _a = 'file:///music/a.flac';
const _b = 'https://music.example.invalid/rest/stream?id=b&t=tok&s=salt';
const _c = '/music/c.flac';

void main() {
  group('hookBoost', () {
    test("an explicit switch starts at the new file's own gain", () {
      expect(hookBoost(explicit: true, lastApplied: 0, target: 6), 6);
      expect(hookBoost(explicit: true, lastApplied: 9, target: 2), 2);
    });

    test("a natural join never starts above the previous file's gain", () {
      expect(hookBoost(explicit: false, lastApplied: 0, target: 6), 0);
      expect(hookBoost(explicit: false, lastApplied: 4, target: 6), 4);
      expect(hookBoost(explicit: false, lastApplied: 9, target: 2), 2);
      expect(hookBoost(explicit: false, lastApplied: 3, target: 3), 3);
    });
  });

  group('replayGainBoostKey', () {
    test('a file URI and the plain path mpv reports are the same key', () {
      expect(replayGainBoostKey('file:///music/a.flac'), '/music/a.flac');
      expect(replayGainBoostKey('/music/a.flac'), '/music/a.flac');
    });

    test('a stream URL keeps its query', () {
      expect(replayGainBoostKey(_b), _b);
    });

    test('the Windows long-path prefix is dropped', () {
      expect(
        replayGainBoostKey(r'\\?\C:\music\a.flac'),
        replayGainBoostKey(r'C:\music\a.flac'),
      );
    });
  });

  group('ReplayGainBoostState', () {
    var now = Duration.zero;
    // A queue [a (+10), b (0), c (+6)] whose first file has just loaded.
    ReplayGainBoostState loaded(Map<String, double> map, String path) {
      final state = ReplayGainBoostState(clock: () => now)
        ..update(map)
        ..expectSwitch(0);
      state.onLoad(position: 0, path: path);
      return state;
    }

    const map = {_a: 10.0, _b: 0.0, _c: 6.0};
    setUp(() => now = Duration.zero);

    test("the first load is explicit and starts at the file's gain", () {
      final state = ReplayGainBoostState(clock: () => now)
        ..update(map)
        ..expectSwitch(0);
      expect(state.onLoad(position: 0, path: '/music/a.flac'), 10);
      expect(state.applied, 10);
      expect(state.held, isNull);
    });

    test("the map update sets the loaded file's gain at once", () {
      final state = loaded(map, '/music/a.flac');
      expect(state.update({...map, _a: 4}), 4);
      expect(state.update({...map, _a: 4}), isNull);
    });

    test('a file not in the map gets no boost', () {
      final state = loaded(map, '/music/a.flac');
      expect(state.update({_b: 3}), 0);
    });

    test('an update before any load changes nothing', () {
      expect(ReplayGainBoostState().update(map), isNull);
    });

    test('a natural join to a higher-boost file is held down, then raised', () {
      final state = loaded({_a: 0, _c: 6}, '/music/a.flac');
      expect(state.onLoad(position: 1, path: '/music/c.flac'), 0);
      expect(state.held, 6);
      expect(state.raiseDue(const Duration(milliseconds: 499)), isNull);
      expect(state.raiseDue(const Duration(milliseconds: 500)), 6);
      expect(state.applied, 6);
      expect(state.held, isNull);
      expect(state.raiseDue(const Duration(seconds: 3)), isNull);
    });

    test('F1: a join to a lower-boost file is held too; a raise waits', () {
      // A=8, B=3: B starts at 3 and is held although nothing is lowered.
      final state = loaded({_a: 8, _b: 3}, '/music/a.flac');
      expect(state.onLoad(position: 1, path: _b), 3);
      expect(state.held, 3);
      // B's value goes up while A's tail is queued: nothing may be written.
      expect(state.update({_a: 8, _b: 9}), isNull);
      expect(state.applied, 3);
      expect(state.held, 9);
      expect(state.raiseDue(const Duration(milliseconds: 600)), 9);
    });

    test('F1: a file missing from the map at the join is not raised early', () {
      final state = loaded({_a: 0}, '/music/a.flac');
      expect(state.onLoad(position: 1, path: _b), 0);
      expect(state.update({_a: 0, _b: 8}), isNull);
      expect(state.applied, 0);
      expect(state.raiseDue(const Duration(milliseconds: 500)), 8);
    });

    test('F1: an update that lowers a held file is written at once', () {
      final state = loaded({_a: 5, _c: 6}, '/music/a.flac');
      expect(state.onLoad(position: 1, path: '/music/c.flac'), 5);
      expect(state.update({_c: 2}), 2);
      expect(state.held, 2);
      expect(state.raiseDue(const Duration(seconds: 1)), isNull);
    });

    test('F1: the raise does not depend on the playlist index', () {
      // Trimming played songs shifts the index while the join is held.
      final state = loaded({_a: 0, _c: 6}, '/music/a.flac');
      state.onLoad(position: 6, path: '/music/c.flac');
      expect(state.raiseDue(const Duration(seconds: 1)), 6);
    });

    test('a natural join to a lower-boost file lowers at once', () {
      final state = loaded(map, '/music/a.flac');
      expect(state.onLoad(position: 1, path: _b), 0);
    });

    test('an explicit switch never waits', () {
      final state = loaded(map, '/music/a.flac')..expectSwitch(1);
      expect(state.onLoad(position: 1, path: '/music/c.flac'), 6);
      expect(state.held, isNull);
    });

    test('F2: a natural-join hook does not consume a pending jump', () {
      final state = loaded(map, '/music/a.flac')..expectSwitch(9);
      // The join to index 1 arrives first: natural, min rule.
      expect(state.onLoad(position: 1, path: _b), 0);
      expect(state.held, 0);
      // The jump's own hook is still explicit.
      expect(state.onLoad(position: 9, path: '/music/c.flac'), 6);
      expect(state.held, isNull);
    });

    test('F2: the expectation is consumed by the load it was set for', () {
      final state = loaded(map, '/music/a.flac')..expectSwitch(1);
      state.onLoad(position: 1, path: '/music/c.flac');
      // The next join uses the min rule again.
      expect(state.onLoad(position: 2, path: '/music/a.flac'), 6);
      expect(state.held, 10);
    });

    test('F2: a switch that loads nothing goes stale instead of lingering', () {
      final state = loaded(map, '/music/a.flac')..expectSwitch(1);
      now += const Duration(seconds: 10);
      // A much later natural join to index 1 is not explicit.
      expect(state.onLoad(position: 1, path: '/music/c.flac'), 6);
      expect(state.held, 6);
    });

    test('F2: an expectation expires on the monotonic clock', () {
      final state = loaded(map, '/music/a.flac')..expectSwitch(1);
      now += const Duration(seconds: 4);
      expect(state.onLoad(position: 1, path: '/music/c.flac'), 6);
      expect(
        state.held,
        isNull,
        reason: 'a fresh expectation makes the hook explicit',
      );
    });

    test('F5: only the position of the landed seek releases the hold', () {
      final state = loaded({_a: 0, _c: 6}, '/music/a.flac');
      state.onLoad(position: 1, path: '/music/c.flac');
      // A seek mpv rejected leaves the early positions: no raise.
      expect(state.raiseDue(const Duration(milliseconds: 40)), isNull);
      expect(state.raiseDue(const Duration(milliseconds: 120)), isNull);
      // Once the position reports the landed seek, the hold ends.
      expect(state.raiseDue(const Duration(seconds: 30)), 6);
    });

    test('a join into a third file keeps the lowest gain seen', () {
      final state = loaded({_a: 0, _c: 6, _b: 9}, '/music/a.flac');
      state.onLoad(position: 1, path: '/music/c.flac'); // held at 0
      expect(state.onLoad(position: 2, path: _b), 0);
      expect(state.held, 9);
    });
  });
}
