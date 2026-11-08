import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/replay_gain_boost.dart';

const _a = 'file:///music/a.flac';
const _b = 'https://music.example.invalid/rest/stream?id=b&t=tok&s=salt';
const _c = '/music/c.flac';

void main() {
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

  group('ReplayGainLevels', () {
    // A queue [a (-9), b (0), c (+6)]; every hook is a plain lookup.
    ReplayGainLevels queue() =>
        ReplayGainLevels()..update({_a: -9, _b: 0, _c: 6}, live: false);

    test("a natural join gives the entering file's own level", () {
      final levels = queue();
      expect(levels.onLoad('/music/a.flac'), -9);
      expect(levels.onLoad(_b), 0);
      expect(levels.onLoad('/music/c.flac'), 6);
    });

    test('jumping back to a song that played earlier with a cut keeps it', () {
      final levels = queue();
      levels.onLoad('/music/a.flac');
      levels.onLoad(_b);
      expect(levels.onLoad('/music/a.flac'), -9);
      expect(levels.current, -9);
    });

    test('a seek into another entry is the same lookup', () {
      final levels = queue();
      levels.onLoad('/music/c.flac');
      expect(levels.onLoad('/music/a.flac'), -9);
    });

    test('a file mpv could not load leaves nothing for the next one', () {
      final levels = queue();
      levels.onLoad('/music/c.flac');
      // The next hook belongs to a file outside the map: no stale 6 dB.
      expect(levels.onLoad('/music/unknown.flac'), 0);
      expect(levels.current, 0);
      expect(levels.onLoad('/music/a.flac'), -9);
    });

    test('an unknown key plays at 0 dB', () {
      expect(ReplayGainLevels().onLoad('/music/a.flac'), 0);
    });

    test('a non-live update does not move the playing entry', () {
      final levels = queue()..onLoad('/music/a.flac');
      expect(levels.update({_a: -4, _b: -2}, live: false), isNull);
      expect(levels.current, -9);
      // It applies from the next start.
      levels.onLoad(_b);
      expect(levels.onLoad('/music/a.flac'), -4);
    });

    test('a live update returns the playing entry new level once', () {
      final levels = queue()..onLoad('/music/a.flac');
      expect(levels.update({_a: -4}, live: true), -4);
      expect(levels.current, -4);
      expect(levels.update({_a: -4}, live: true), isNull);
    });

    test('a live update before any file loaded changes nothing', () {
      expect(ReplayGainLevels().update({_a: -4}, live: true), isNull);
    });

    test('a seeded source is found by the URI form mpv reports', () {
      final levels = ReplayGainLevels()..seed(r'\\?\C:\music\a.flac', -3);
      expect(levels.onLoad(r'C:\music\a.flac'), -3);
    });

    test('a new queue forgets the old levels but not the heard file', () {
      final levels = queue()..onLoad('/music/a.flac');
      levels.clear();
      expect(levels.current, -9, reason: 'the old file is still playing');
      expect(levels.onLoad('/music/a.flac'), 0);
    });

    test(
      'a live push between clear and the next hook leaves the heard file',
      () {
        final levels = queue()..onLoad('/music/a.flac');
        levels.clear();
        expect(levels.update({'/music/x.flac': -3}, live: true), isNull);
        expect(levels.current, -9);
        expect(levels.onLoad('/music/x.flac'), -3);
      },
    );

    test('a level that is not finite plays at 0 dB', () {
      final levels = ReplayGainLevels()..seed(_a, double.nan);
      expect(levels.onLoad('/music/a.flac'), 0);
    });
  });
}
