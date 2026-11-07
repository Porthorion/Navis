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
    // A queue [a (+10), b (0), c (+6)] whose first file has just loaded.
    ReplayGainBoostState loaded(Map<String, double> map, String path) =>
        ReplayGainBoostState()
          ..update(map)
          ..onLoad(index: 0, path: path);
    const map = {_a: 10.0, _b: 0.0, _c: 6.0};

    test("the first load is explicit and starts at the file's gain", () {
      final state = ReplayGainBoostState()..update(map);
      expect(state.onLoad(index: 0, path: '/music/a.flac'), 10);
      expect(state.applied, 10);
      expect(state.armed, isNull);
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
      final state = loaded({_a: 0, _c: 6}, '/music/a.flac')
        ..explicitSwitch = false;
      expect(state.onLoad(index: 1, path: '/music/c.flac'), 0);
      expect(state.armed, (index: 1, target: 6.0));
      expect(state.raiseDue(1, const Duration(milliseconds: 499)), isNull);
      expect(state.raiseDue(0, const Duration(seconds: 2)), isNull);
      expect(state.raiseDue(1, const Duration(milliseconds: 500)), 6);
      expect(state.applied, 6);
      expect(state.armed, isNull);
      expect(state.raiseDue(1, const Duration(seconds: 3)), isNull);
    });

    test("the player's early index event cannot raise a held-down join", () {
      // The Dart side re-sends the map as soon as the player's entry moves
      // on, while the end of the previous file is still queued in mpv.
      final state = loaded({_a: 0, _c: 6}, '/music/a.flac')
        ..explicitSwitch = false;
      state.onLoad(index: 1, path: '/music/c.flac');
      expect(state.update({_a: 0, _c: 6}), isNull);
      expect(state.applied, 0);
    });

    test('a natural join to a lower-boost file lowers at once, no raise', () {
      final state = loaded(map, '/music/a.flac')..explicitSwitch = false;
      expect(state.onLoad(index: 1, path: _b), 0);
      expect(state.armed, isNull);
    });

    test('an explicit switch never waits', () {
      final state = loaded(map, '/music/a.flac')..explicitSwitch = true;
      expect(state.onLoad(index: 1, path: '/music/c.flac'), 6);
      expect(state.armed, isNull);
    });

    test('the explicit flag is consumed by the load it was set for', () {
      final state = loaded(map, '/music/a.flac')..explicitSwitch = true;
      state.onLoad(index: 1, path: '/music/c.flac');
      expect(state.explicitSwitch, isFalse);
    });

    test('an update while a raise is armed moves the target, not the gain', () {
      final state = loaded({_a: 0, _c: 6}, '/music/a.flac')
        ..explicitSwitch = false;
      state.onLoad(index: 1, path: '/music/c.flac');
      expect(state.update({_c: 8}), isNull);
      expect(state.armed, (index: 1, target: 8.0));
      expect(state.applied, 0);
    });

    test('an update that lowers an armed file applies at once', () {
      final state = loaded({_a: 5, _c: 6}, '/music/a.flac')
        ..explicitSwitch = false;
      expect(state.onLoad(index: 1, path: '/music/c.flac'), 5);
      expect(state.update({_c: 2}), 2);
      expect(state.armed, isNull);
    });

    test('a seek in the same file ends the hold at once', () {
      final state = loaded({_a: 0, _c: 6}, '/music/a.flac')
        ..explicitSwitch = false;
      state.onLoad(index: 1, path: '/music/c.flac');
      expect(state.raiseNow(), 6);
      expect(state.raiseNow(), isNull);
    });

    test('a join into a third file keeps the lowest gain seen', () {
      final state = loaded({_a: 0, _c: 6, _b: 9}, '/music/a.flac')
        ..explicitSwitch = false;
      state.onLoad(index: 1, path: '/music/c.flac'); // held at 0
      expect(state.onLoad(index: 2, path: _b), 0);
      expect(state.armed, (index: 2, target: 9.0));
    });
  });
}
