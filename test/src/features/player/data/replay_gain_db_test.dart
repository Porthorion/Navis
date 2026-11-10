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
  }) => replayGainLevels(
    mode: mode,
    trackGain: track,
    albumGain: album,
    trackPeak: trackPeak,
    albumPeak: albumPeak,
    preampDb: preamp,
    untaggedDb: untagged,
    boostSupported: true,
  )?.cutDb;

  double? boost({
    String mode = 'track',
    double? track,
    double? album,
    double? trackPeak,
    double? albumPeak,
    double preamp = 0,
    double untagged = -8,
    bool supported = true,
  }) => replayGainLevels(
    mode: mode,
    trackGain: track,
    albumGain: album,
    trackPeak: trackPeak,
    albumPeak: albumPeak,
    preampDb: preamp,
    untaggedDb: untagged,
    boostSupported: supported,
  )?.boostDb;

  /// The rule before the boost existed: the reference every cut must match.
  double oldReplayGainDb({
    double? gain,
    double? peak,
    double preamp = 0,
    double untagged = -8,
  }) {
    var value = (gain ?? untagged) + preamp.clamp(-6.0, 6.0);
    if (gain != null &&
        peak != null &&
        peak.isFinite &&
        peak > 0 &&
        peak <= 4) {
      value = math.min(value, -20 * math.log(peak) / math.ln10);
    }
    return math.min(value, 0);
  }

  double ceilingOf(double peak) => -20 * math.log(peak) / math.ln10;

  group('replayGainLevels', () {
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

    test('the cut never goes above 0 dB; the boost is separate', () {
      expect(db(track: 14.4), 0);
      expect(db(track: 3, preamp: 6), 0);
      expect(boost(track: 14.4), 0, reason: 'no peak, no boost');
    });

    test('boost: the gain, stopping 1 dB under the peak ceiling', () {
      // Cardigan: gain +6.6, peak -7.2 dB (ceiling 7.2) -> min(6.6, 6.2).
      final cardigan = math.pow(10, -7.2 / 20).toDouble();
      expect(boost(track: 6.6, trackPeak: cardigan), closeTo(6.2, 0.001));
      expect(db(track: 6.6, trackPeak: cardigan), 0);
      // Rockline: gain +2.9, peak -1.9 dB -> +0.9.
      final rockline = math.pow(10, -1.9 / 20).toDouble();
      expect(boost(track: 2.9, trackPeak: rockline), closeTo(0.9, 0.001));
      // Plenty of room: the gain itself.
      expect(boost(track: 3, trackPeak: 0.1), 3);
    });

    test('boost needs both a gain and a valid peak', () {
      expect(boost(track: 6), 0);
      expect(boost(track: 6, trackPeak: 0), 0);
      expect(boost(track: 6, trackPeak: 4.5), 0);
      expect(boost(track: 6, trackPeak: double.nan), 0);
      expect(boost(track: 6, trackPeak: double.infinity), 0);
      expect(boost(track: 6, trackPeak: -1), 0);
    });

    test('a peak at or above full scale leaves no room', () {
      expect(boost(track: 6, trackPeak: 1), 0);
      expect(boost(track: 6, trackPeak: 1.2), 0);
      expect(boost(track: 6, trackPeak: 0.95), 0);
    });

    test('untagged songs are never boosted, whatever the pre-amp', () {
      expect(boost(preamp: 6, untagged: 0), 0);
      expect(boost(preamp: 6), 0);
      expect(db(preamp: 6, untagged: 0), 0);
    });

    test('a gain beyond 24 dB is garbage and never boosts', () {
      expect(boost(track: 30, trackPeak: 0.001), 0);
    });

    test('a positive pre-amp lifts tagged songs up to their ceiling', () {
      expect(boost(track: 1, preamp: 6, trackPeak: 0.1), 7);
      expect(
        boost(track: 1, preamp: 6, trackPeak: 0.5),
        closeTo(ceilingOf(0.5) - 1, 0.001),
      );
      // Negative total: no boost at all.
      expect(boost(track: -10, preamp: 6, trackPeak: 0.1), 0);
    });

    test('the boost is capped at 12 dB', () {
      expect(boost(track: 20, trackPeak: 0.0001), replayGainMaxBoostDb);
      expect(replayGainMaxBoostDb, 12);
    });

    test('album mode boosts with the album peak; a missing one means 0', () {
      expect(
        boost(
          mode: 'album',
          track: 1,
          album: 5,
          trackPeak: 0.1,
          albumPeak: 0.2,
        ),
        5,
      );
      expect(boost(mode: 'album', track: 1, album: 5, trackPeak: 0.1), 0);
      // Track-gain fallback under album mode keeps the track peak pairing.
      expect(boost(mode: 'album', track: 4, trackPeak: 0.1, albumPeak: 0.9), 4);
    });

    test('unsupported platforms never boost and cut exactly as before', () {
      expect(boost(track: 6, trackPeak: 0.1, supported: false), 0);
      final levels = replayGainLevels(
        mode: 'track',
        trackGain: -6,
        trackPeak: 0.1,
        untaggedDb: -8,
        boostSupported: false,
      )!;
      expect((levels.cutDb, levels.boostDb), (-6.0, 0.0));
    });

    test('every cut is identical to the rule before the boost existed', () {
      for (final gain in <double?>[null, -20, -6, 0, 2.5, 8, 14.4, 30]) {
        for (final peak in <double?>[null, 0, 0.05, 0.5, 0.95, 1, 1.5, 4, 5]) {
          for (final preamp in <double>[-8, -3, 0, 2, 6, 9]) {
            for (final untagged in <double>[-15, -8, -0.5, 0]) {
              final usable = gain != null && gain.abs() <= replayGainMaxAbsDb;
              expect(
                db(
                  track: gain,
                  trackPeak: peak,
                  preamp: preamp,
                  untagged: untagged,
                ),
                oldReplayGainDb(
                  gain: usable ? gain : null,
                  peak: usable ? peak : null,
                  preamp: preamp,
                  untagged: untagged,
                ),
                reason: '$gain/$peak/$preamp/$untagged',
              );
            }
          }
        }
      }
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

  test('new profiles and unloaded settings default to smart mode', () {
    expect(const AppSettingsModel.defaults().replayGainMode, 'smart');
    expect(const PlaybackRuntimeSettings.defaults().replayGainMode, 'smart');
  });

  group('resolveReplayGainMode', () {
    String smart({String? album, String? prev, String? next}) =>
        resolveReplayGainMode(
          'smart',
          albumId: album,
          prevAlbumId: prev,
          nextAlbumId: next,
        );

    test('an album played in order gets album gain at every position', () {
      expect(smart(album: 'a', next: 'a'), 'album'); // first track
      expect(smart(album: 'a', prev: 'a', next: 'a'), 'album'); // middle
      expect(smart(album: 'a', prev: 'a'), 'album'); // last track
    });

    test('a song alone, or among other albums, gets track gain', () {
      expect(smart(album: 'a'), 'track');
      expect(smart(album: 'a', prev: 'b', next: 'c'), 'track');
    });

    test('a shuffled album (every neighbour the same album) is album', () {
      expect(smart(album: 'a', prev: 'a', next: 'a'), 'album');
    });

    test('a null album id never matches, not even another null', () {
      expect(smart(prev: 'a', next: 'a'), 'track');
      // Remote songs with the same albumName but no id have null ids.
      expect(smart(), 'track');
    });

    test('an empty album id counts as null', () {
      expect(smart(album: '', prev: '', next: ''), 'track');
      expect(smart(album: 'a', prev: '', next: ''), 'track');
    });

    test('the other modes pass through unchanged', () {
      for (final mode in ['off', 'track', 'album']) {
        expect(
          resolveReplayGainMode(
            mode,
            albumId: 'a',
            prevAlbumId: 'a',
            nextAlbumId: 'a',
          ),
          mode,
        );
      }
    });
  });

  group('replayGainDecision', () {
    ReplayGainDecision decide({
      String mode = 'smart',
      String? album,
      String? prev,
      String? next,
      double? track,
      double? albumGain,
      double? trackPeak,
      double preamp = 0,
      bool boostSupported = false,
    }) => replayGainDecision(
      boostSupported: boostSupported,
      mode: mode,
      albumId: album,
      prevAlbumId: prev,
      nextAlbumId: next,
      trackGain: track,
      albumGain: albumGain,
      trackPeak: trackPeak,
      preampDb: preamp,
      untaggedDb: -8,
    );

    test('smart in an album run uses the album gain and says so', () {
      final d = decide(album: 'a', next: 'a', track: -10, albumGain: -4);
      expect(d.db, -4);
      expect(d.source, ReplayGainSource.album);
      expect(d.resolvedMode, 'album');
      expect(d.mode, 'smart');
    });

    test('smart among other albums uses the track gain', () {
      final d = decide(album: 'a', prev: 'b', track: -10, albumGain: -4);
      expect(d.db, -10);
      expect(d.source, ReplayGainSource.track);
      expect(d.resolvedMode, 'track');
    });

    test('the source is the gain actually used, after the fallback', () {
      // Album chosen but only a track gain exists.
      final d = decide(album: 'a', next: 'a', track: -10);
      expect(d.resolvedMode, 'album');
      expect(d.source, ReplayGainSource.track);
      expect(d.db, -10);
    });

    test('an untagged song reports the untagged level', () {
      final d = decide(album: 'a', next: 'a');
      expect(d.source, ReplayGainSource.untagged);
      expect(d.db, -8);
    });

    test('a fixed mode stays as set; off has no gain', () {
      final fixed = decide(mode: 'track', album: 'a', next: 'a', track: -10);
      expect(fixed.mode, 'track');
      expect(fixed.resolvedMode, 'track');
      final off = decide(mode: 'off', track: -10);
      expect(off.db, isNull);
      expect(off.source, isNull);
      expect(off.resolvedMode, 'off');
    });

    test('decision cut equals the rule for the resolved mode', () {
      final d = decide(
        album: 'a',
        next: 'a',
        track: -10,
        albumGain: -4,
        trackPeak: 0.5,
        preamp: 2,
      );
      expect(
        d.cutDb,
        replayGainLevels(
          mode: 'album',
          trackGain: -10,
          albumGain: -4,
          trackPeak: 0.5,
          preampDb: 2,
          untaggedDb: -8,
          boostSupported: true,
        )!.cutDb,
      );
    });

    test('a boosted song reports a signed db and the cut stays 0', () {
      final d = decide(track: 6, trackPeak: 0.1, boostSupported: true);
      expect(d.cutDb, 0);
      expect(d.boostDb, 6);
      expect(d.db, 6);
    });

    test('boost is 0 and db is the cut when the platform cannot boost', () {
      final d = decide(track: 6, trackPeak: 0.1);
      expect(d.boostDb, 0);
      expect(d.db, 0);
    });

    test('a cut reports its own db and no boost', () {
      final d = decide(track: -6, trackPeak: 0.1, boostSupported: true);
      expect((d.cutDb, d.boostDb, d.db), (-6.0, 0.0, -6.0));
    });

    test('off has no cut, boost or db', () {
      final d = decide(
        mode: 'off',
        track: 6,
        trackPeak: 0.1,
        boostSupported: true,
      );
      expect((d.cutDb, d.boostDb, d.db), (null, 0.0, null));
    });

    test('toJson reports the diagnostics fields', () {
      final d = decide(album: 'a', next: 'a', track: -10, albumGain: -4);
      expect(d.toJson(), {
        'mode': 'smart',
        'resolvedMode': 'album',
        'source': 'album',
        'db': -4.0,
        'cutDb': -4.0,
        'boostDb': 0.0,
      });
      final boosted = decide(track: 6, trackPeak: 0.1, boostSupported: true);
      expect(boosted.toJson()['cutDb'], 0.0);
      expect(boosted.toJson()['boostDb'], 6.0);
      expect(boosted.toJson()['db'], 6.0);
    });
  });

  group('replayGainBoostPlatformSupported', () {
    test('mpv boosts on every desktop, macOS included (#490)', () {
      expect(navisReplayGainBoostSupported(usesMpv: true), isTrue);
      expect(navisReplayGainBoostSupported(usesMpv: false), isFalse);
    });

    test('the filter stage is on mpv, which covers macOS (#490)', () {
      expect(navisReplayGainInPipeline(usesMpv: true), isTrue);
      expect(navisReplayGainInPipeline(usesMpv: false), isFalse);
    });

    test('the Android processor turns the stage on without mpv', () {
      expect(
        navisReplayGainInPipeline(usesMpv: false, androidProcessor: true),
        isTrue,
      );
      // iOS and a rebuilt Android player (no processor) keep the Dart cut.
      expect(
        navisReplayGainInPipeline(usesMpv: false, androidProcessor: false),
        isFalse,
      );
    });

    test('Android boosts while its EQ processor pipeline is installed', () {
      expect(
        navisReplayGainBoostSupported(usesMpv: false, androidProcessor: true),
        isTrue,
      );
      expect(
        navisReplayGainBoostSupported(usesMpv: false, androidProcessor: false),
        isFalse,
        reason: 'the player was rebuilt without the processor',
      );
    });

    test('iOS boosts while the tap pipeline is installed (I24)', () {
      expect(
        navisReplayGainBoostSupported(usesMpv: false, iosTap: true),
        isTrue,
      );
      expect(
        navisReplayGainBoostSupported(usesMpv: false, iosTap: false),
        isFalse,
        reason: 'the player was rebuilt without the tap',
      );
    });
  });

  test('no song is ever both cut and boosted, so no gain applies twice', () {
    // iOS applies the cut on AVPlayer.volume and the boost in the tap.
    for (final mode in ['track', 'album']) {
      for (final gain in [-20.0, -6.0, -0.5, 0.0, 0.5, 3.0, 9.0, 14.4]) {
        for (final peak in [null, 0.05, 0.3, 0.5, 0.9, 1.0, 1.5]) {
          for (final preamp in [-6.0, 0.0, 6.0]) {
            for (final untagged in [-8.0, 0.0]) {
              final levels = replayGainLevels(
                mode: mode,
                trackGain: mode == 'track' ? gain : null,
                albumGain: mode == 'album' ? gain : null,
                trackPeak: mode == 'track' ? peak : null,
                albumPeak: mode == 'album' ? peak : null,
                preampDb: preamp,
                untaggedDb: untagged,
                boostSupported: true,
              )!;
              final reason =
                  '$mode gain $gain peak $peak preamp $preamp untagged $untagged';
              expect(levels.cutDb, lessThanOrEqualTo(0), reason: reason);
              expect(levels.boostDb, inInclusiveRange(0, 12), reason: reason);
              if (levels.boostDb > 0) {
                expect(levels.cutDb, 0, reason: reason);
              }
            }
          }
        }
      }
    }
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
