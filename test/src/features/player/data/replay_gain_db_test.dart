import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';

void main() {
  double? db({
    String mode = 'track',
    double? track,
    double? album,
    double? trackPeak,
    double? albumPeak,
    double preamp = 0,
    double untagged = -8,
  }) => replayGainDb(
    mode: mode,
    trackGain: track,
    albumGain: album,
    trackPeak: trackPeak,
    albumPeak: albumPeak,
    preampDb: preamp,
    untaggedDb: untagged,
  );

  group('replayGainDb', () {
    test('off applies nothing, even to tagged songs', () {
      expect(db(mode: 'off', track: -10), isNull);
      expect(db(mode: 'off'), isNull);
    });

    test('track mode uses the track gain, album mode the album gain', () {
      expect(db(track: -10, album: -5), -10);
      expect(db(mode: 'album', track: -10, album: -5), -5);
    });

    test('each mode falls back to the other gain', () {
      expect(db(album: -5), -5);
      expect(db(mode: 'album', track: -10), -10);
    });

    test('a garbage gain counts as missing', () {
      expect(db(track: 918, album: -5), -5);
      expect(db(track: -40, album: -5), -5);
      expect(db(track: 918, untagged: -9), -9);
      expect(db(track: -24.1), -8);
      expect(db(track: -24), -24);
    });

    test('untagged songs take the untagged level', () {
      expect(db(untagged: -9.1), -9.1);
      expect(db(untagged: 0), 0);
    });

    test('never boosts: positive gain is capped at 0 dB', () {
      expect(db(track: 14.4), 0);
      expect(db(track: 3, preamp: 6), 0);
    });

    test('the pre-amp is added and clamped to -6..6', () {
      expect(db(track: -10, preamp: 3), -7);
      expect(db(track: -10, preamp: 20), -4);
      expect(db(track: -10, preamp: -20), -16);
      expect(db(preamp: -2, untagged: -8), -10);
    });

    test('a known peak limits the result', () {
      // Peak 2.0 (clipped master) allows at most -6.02 dB.
      final limit = -20 * math.log(2) / math.ln10;
      expect(db(track: -2, trackPeak: 2), closeTo(limit, 0.0001));
      // Quiet peak never raises a lower gain.
      expect(db(track: -10, trackPeak: 0.5), -10);
      // Album mode reads the album peak.
      expect(
        db(mode: 'album', track: -2, album: -1, trackPeak: 4, albumPeak: 2),
        closeTo(limit, 0.0001),
      );
      // Zero or negative peaks are ignored.
      expect(db(track: -2, trackPeak: 0), -2);
    });

    test('garbage peaks are ignored', () {
      // An int-scale peak (32768) would otherwise silence the song.
      expect(db(track: -2, trackPeak: 32768), -2);
      expect(db(track: -2, trackPeak: 4.5), -2);
      expect(db(track: -2, trackPeak: -1), -2);
      expect(db(track: -2, trackPeak: double.nan), -2);
      expect(db(track: -2, trackPeak: double.infinity), -2);
      // 4.0 is the largest believable peak (-12.04 dB).
      expect(db(track: -2, trackPeak: 4), closeTo(-12.0412, 0.001));
    });
  });

  test('new profiles and unloaded settings default to track mode', () {
    expect(const AppSettingsModel.defaults().replayGainMode, 'track');
    expect(const PlaybackRuntimeSettings.defaults().replayGainMode, 'track');
  });

  group('automaticUntaggedGainDb', () {
    test('uses the median once 20 songs are tagged', () {
      expect(automaticUntaggedGainDb(taggedCount: 20, median: -9.1), -9.1);
    });

    test('falls back to -8 dB below 20 tagged songs or without a median', () {
      expect(automaticUntaggedGainDb(taggedCount: 19, median: -9.1), -8);
      expect(automaticUntaggedGainDb(taggedCount: 0), -8);
      expect(automaticUntaggedGainDb(taggedCount: 50), -8);
    });

    test('stays within -15..0 dB', () {
      expect(automaticUntaggedGainDb(taggedCount: 99, median: 2), 0);
      expect(automaticUntaggedGainDb(taggedCount: 99, median: -20), -15);
    });
  });
}
