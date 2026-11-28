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
    ReplayGainLoudness loudness = ReplayGainLoudness.custom,
    bool limiter = false,
  }) => replayGainLevels(
    mode: mode,
    trackGain: track,
    albumGain: album,
    trackPeak: trackPeak,
    albumPeak: albumPeak,
    loudness: loudness,
    preampDb: preamp,
    untaggedDb: untagged,
    boostSupported: true,
    limiterSupported: limiter,
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
    ReplayGainLoudness loudness = ReplayGainLoudness.custom,
    bool limiter = false,
  }) => replayGainLevels(
    mode: mode,
    trackGain: track,
    albumGain: album,
    trackPeak: trackPeak,
    albumPeak: albumPeak,
    loudness: loudness,
    preampDb: preamp,
    untaggedDb: untagged,
    boostSupported: supported,
    limiterSupported: limiter,
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
        loudness: ReplayGainLoudness.custom,
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
          for (final preamp in <double>[-8, -3, 0, 2, 4, 6]) {
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

    test('the pre-amp is added and clamped to -6..8', () {
      expect(db(track: -10, preamp: 3), -7);
      expect(db(track: -10, preamp: 20), -2);
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
      ReplayGainLoudness loudness = ReplayGainLoudness.custom,
      bool limiter = false,
    }) => replayGainDecision(
      loudness: loudness,
      limiterSupported: limiter,
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
          loudness: ReplayGainLoudness.custom,
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

    test('toJson reports the loudness offset and whether limiting applied', () {
      Map<String, Object?> json(
        ReplayGainLoudness l, {
        required bool limiter,
      }) => decide(
        track: -2,
        trackPeak: 1,
        boostSupported: true,
        loudness: l,
        limiter: limiter,
      ).toJson();
      final loud = json(ReplayGainLoudness.loud, limiter: true);
      expect((loud['offsetDb'], loud['limited']), (7.0, true));
      final noLimiter = json(ReplayGainLoudness.loud, limiter: false);
      expect((noLimiter['offsetDb'], noLimiter['limited']), (7.0, false));
      final normal = json(ReplayGainLoudness.normal, limiter: true);
      expect((normal['offsetDb'], normal['limited']), (4.0, false));
      expect(
        decide(
          mode: 'off',
          loudness: ReplayGainLoudness.loud,
          limiter: true,
        ).toJson()['limited'],
        isFalse,
      );
    });

    test('limited only when the boost passes the no-limiter room', () {
      bool limited(double track, {required double peak}) => decide(
        track: track,
        trackPeak: peak,
        boostSupported: true,
        loudness: ReplayGainLoudness.loud,
        limiter: true,
      ).limited;
      // Peak 0.1 (ceiling 20 dB): raw 13 stays under ceiling - 1, no limiter
      // needed even though Loud limiting is on.
      expect(limited(6, peak: 0.1), isFalse);
      // Peak 1.0 (ceiling 0): raw +5 passes ceiling - 1 (room 0).
      expect(limited(-2, peak: 1), isTrue);
      // A cut is never limited.
      expect(limited(-20, peak: 1), isFalse);
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
        'offsetDb': 0.0,
        'limited': false,
      });
      final boosted = decide(track: 6, trackPeak: 0.1, boostSupported: true);
      expect(boosted.toJson()['cutDb'], 0.0);
      expect(boosted.toJson()['boostDb'], 6.0);
      expect(boosted.toJson()['db'], 6.0);
    });
  });

  group('navisReplayGainLimiterSupported', () {
    test('mpv has one only when its probe found alimiter', () {
      expect(
        navisReplayGainLimiterSupported(usesMpv: true, mpvLimiter: true),
        isTrue,
      );
      expect(
        navisReplayGainLimiterSupported(usesMpv: true, mpvLimiter: false),
        isFalse,
      );
      expect(
        navisReplayGainLimiterSupported(usesMpv: false, mpvLimiter: true),
        isFalse,
      );
    });

    test('the Android processor and the iOS tap each carry one', () {
      expect(
        navisReplayGainLimiterSupported(
          usesMpv: false,
          mpvLimiter: false,
          androidProcessor: true,
        ),
        isTrue,
      );
      expect(
        navisReplayGainLimiterSupported(
          usesMpv: false,
          mpvLimiter: false,
          iosTap: true,
        ),
        isTrue,
      );
      expect(
        navisReplayGainLimiterSupported(usesMpv: false, mpvLimiter: false),
        isFalse,
        reason: 'a rebuild without the EQ pipeline has no limiter',
      );
    });
  });

  group('loudness presets', () {
    test('the offsets: Quiet 0, Normal +4, Loud +7, Custom -6..+8', () {
      double offset(ReplayGainLoudness l, [double custom = 0]) =>
          replayGainOffsetDb(l, custom);
      expect(offset(ReplayGainLoudness.quiet, 5), 0);
      expect(offset(ReplayGainLoudness.normal, 5), 4);
      expect(offset(ReplayGainLoudness.loud, -5), 7);
      expect(offset(ReplayGainLoudness.custom, 3.5), 3.5);
      expect(offset(ReplayGainLoudness.custom, 20), 8);
      expect(offset(ReplayGainLoudness.custom, -20), -6);
    });

    test('limiting needs a confirmed limiter and an offset above Normal', () {
      for (final limiter in [false, true]) {
        for (final offset in [-6.0, 0.0, 4.0, 4.1, 7.0, 8.0]) {
          expect(
            replayGainLimiting(offsetDb: offset, limiterSupported: limiter),
            limiter && offset > 4,
            reason: 'limiter $limiter offset $offset',
          );
        }
      }
    });

    test('Loud on a full-scale song with a limiter boosts, limited', () {
      // Peak 1.0 (ceiling 0), gain -2 -> raw +5, within the 6 dB depth cap.
      final levels = replayGainLevels(
        mode: 'track',
        trackGain: -2,
        trackPeak: 1,
        loudness: ReplayGainLoudness.loud,
        untaggedDb: -8,
        boostSupported: true,
        limiterSupported: true,
      )!;
      expect((levels.cutDb, levels.boostDb), (0.0, 5.0));
    });

    test('the limiter does at most 6 dB: boost stops at ceiling + 6', () {
      const loud = ReplayGainLoudness.loud;
      expect(replayGainMaxLimitDb, 6);
      // Peak 0.5 (ceiling 6.02), gain 3 -> raw 10: 12.02 > 10, the raw gain.
      expect(
        boost(track: 3, trackPeak: 0.5, loudness: loud, limiter: true),
        10,
      );
      // Peak 1.0, gain 3 -> raw 10, but the ceiling + 6 = 6.
      expect(boost(track: 3, trackPeak: 1, loudness: loud, limiter: true), 6);
      // 12 dB stays the absolute cap.
      expect(
        boost(track: 20, trackPeak: 0.0001, loudness: loud, limiter: true),
        12,
      );
    });

    test('a peak above full scale keeps its forced cut and gets no boost', () {
      const loud = ReplayGainLoudness.loud;
      final ceiling = ceilingOf(1.2);
      final levels = replayGainLevels(
        mode: 'track',
        trackGain: -5,
        trackPeak: 1.2,
        loudness: loud,
        untaggedDb: -8,
        boostSupported: true,
        limiterSupported: true,
      )!;
      // raw +2 is above the ceiling (-1.58): the cut is the ceiling, as today.
      expect(levels.cutDb, closeTo(ceiling, 0.0001));
      expect(levels.boostDb, 0);
      expect(boost(track: 3, trackPeak: 1.2, loudness: loud, limiter: true), 0);
    });

    test(
      'untagged songs are never boosted at Loud, they follow the preset',
      () {
        const loud = ReplayGainLoudness.loud;
        expect(boost(untagged: 0, loudness: loud, limiter: true), 0);
        expect(boost(untagged: -2, loudness: loud, limiter: true), 0);
        // The offset moves their cut: -8 + 4 = -4 at Normal, -1 at Loud.
        expect(db(loudness: ReplayGainLoudness.normal), -4);
        expect(db(loudness: loud), -1);
        expect(db(loudness: ReplayGainLoudness.quiet), -8);
      },
    );

    test('Normal never boosts past the ceiling, even with a limiter', () {
      final normal = ReplayGainLoudness.normal;
      expect(boost(track: 3, trackPeak: 1, loudness: normal, limiter: true), 0);
      expect(
        boost(track: 3, trackPeak: 0.5, loudness: normal, limiter: true),
        closeTo(ceilingOf(0.5) - 1, 0.0001),
      );
    });

    test('Loud without a confirmed limiter is capped at the peak ceiling', () {
      const loud = ReplayGainLoudness.loud;
      expect(boost(track: 3, trackPeak: 1, loudness: loud), 0);
      expect(
        boost(track: 3, trackPeak: 0.5, loudness: loud),
        closeTo(ceilingOf(0.5) - 1, 0.0001),
      );
    });

    test('off gives nothing at any preset', () {
      for (final loudness in ReplayGainLoudness.values) {
        expect(
          replayGainLevels(
            mode: 'off',
            trackGain: 1,
            trackPeak: 0.1,
            loudness: loudness,
            untaggedDb: -8,
            boostSupported: true,
            limiterSupported: true,
          ),
          isNull,
        );
      }
    });

    test('Custom 7 is exactly Loud and Custom 4 is exactly Normal', () {
      for (final gain in <double?>[null, -12, -3, 0, 2, 9]) {
        for (final peak in <double?>[null, 0.5, 1, 1.4]) {
          for (final limiter in [false, true]) {
            for (final (custom, preset) in [
              (7.0, ReplayGainLoudness.loud),
              (4.0, ReplayGainLoudness.normal),
              (0.0, ReplayGainLoudness.quiet),
            ]) {
              Object? levels(ReplayGainLoudness l, double c) {
                final r = replayGainLevels(
                  mode: 'track',
                  trackGain: gain,
                  trackPeak: peak,
                  loudness: l,
                  preampDb: c,
                  untaggedDb: -8,
                  boostSupported: true,
                  limiterSupported: limiter,
                );
                return (r!.cutDb, r.boostDb);
              }

              expect(
                levels(ReplayGainLoudness.custom, custom),
                levels(preset, 99),
                reason: '$gain/$peak/$limiter/$preset',
              );
            }
          }
        }
      }
    });

    test('without limiting the rule is the old one with the wider clamp', () {
      // Offsets up to +8 with no limiter (or at most +4): ceiling-capped.
      for (final gain in <double?>[null, -20, -6, 0, 2.5, 8, 14.4]) {
        for (final peak in <double?>[null, 0.05, 0.5, 0.95, 1, 1.5, 4]) {
          for (final preamp in <double>[-8, -3, 0, 4, 6, 7, 8, 9.5]) {
            for (final untagged in <double>[-15, -8, 0]) {
              final clamped = preamp.clamp(-6.0, 8.0);
              final oldCut = oldReplayGainDb(
                gain: gain,
                peak: peak,
                preamp: clamped.clamp(-6.0, 6.0),
                untagged: untagged,
              );
              // Cut agrees with the old rule wherever the old clamp agrees.
              if (clamped <= 6) {
                expect(
                  db(
                    track: gain,
                    trackPeak: peak,
                    preamp: preamp,
                    untagged: untagged,
                  ),
                  oldCut,
                  reason: '$gain/$peak/$preamp/$untagged',
                );
              }
              // Peak-capped boost, with and without a (disarmed) limiter.
              final b = boost(
                track: gain,
                trackPeak: peak,
                preamp: preamp,
                untagged: untagged,
              )!;
              final validPeak = peak != null && peak > 0 && peak <= 4;
              if (gain == null || !validPeak) {
                expect(b, 0);
              } else {
                expect(b, lessThanOrEqualTo(math.max(0, ceilingOf(peak) - 1)));
              }
              if (preamp <= 4) {
                expect(
                  boost(
                    track: gain,
                    trackPeak: peak,
                    preamp: preamp,
                    untagged: untagged,
                    limiter: true,
                  ),
                  b,
                  reason: 'a limiter changes nothing at offsets up to +4',
                );
              }
            }
          }
        }
      }
    });

    test('oracle grid: preset x tagged x peak x limiter x gain', () {
      double? ceilingFor(double? peak) =>
          peak != null && peak > 0 && peak <= 4 ? ceilingOf(peak) : null;
      for (final loudness in ReplayGainLoudness.values) {
        for (final custom
            in loudness == ReplayGainLoudness.custom
                ? <double>[-9, -2, 3, 5.5, 8, 11]
                : <double>[0]) {
          for (final limiter in [false, true]) {
            for (final peak in <double?>[null, 1.0, 0.5, 0.01, 1.3]) {
              for (final gain in <double?>[null, -14, -4, 0, 1.5, 6, 18]) {
                final offset = switch (loudness) {
                  ReplayGainLoudness.quiet => 0.0,
                  ReplayGainLoudness.normal => 4.0,
                  ReplayGainLoudness.loud => 7.0,
                  ReplayGainLoudness.custom => custom.clamp(-6.0, 8.0),
                };
                final raw = (gain ?? -8) + offset;
                final ceiling = gain == null ? null : ceilingFor(peak);
                final cut = math.min(
                  0.0,
                  ceiling == null ? raw : math.min(raw, ceiling),
                );
                final limiting = limiter && offset > 4;
                var expected = 0.0;
                if (ceiling != null && cut == 0) {
                  expected = math.max(
                    0.0,
                    math.min(
                      12,
                      limiting
                          ? math.min(raw, ceiling + replayGainMaxLimitDb)
                          : math.min(raw, ceiling - replayGainBoostMarginDb),
                    ),
                  );
                }
                final levels = replayGainLevels(
                  mode: 'track',
                  trackGain: gain,
                  trackPeak: peak,
                  loudness: loudness,
                  preampDb: custom,
                  untaggedDb: -8,
                  boostSupported: true,
                  limiterSupported: limiter,
                )!;
                final reason =
                    '${loudness.name}/$custom limiter $limiter peak $peak '
                    'gain $gain';
                expect(levels.cutDb, closeTo(cut, 1e-9), reason: reason);
                expect(levels.boostDb, closeTo(expected, 1e-9), reason: reason);
                if (levels.boostDb > 0) expect(levels.cutDb, 0);
                // A boost past the peak ceiling needs the limiter.
                if (ceiling != null && !limiting) {
                  expect(
                    levels.boostDb,
                    lessThanOrEqualTo(math.max(0, ceiling)),
                  );
                }
              }
            }
          }
        }
      }
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
      // A rebuilt Android player (no processor) keeps the Dart cut.
      expect(
        navisReplayGainInPipeline(usesMpv: false, androidProcessor: false),
        isFalse,
      );
    });

    test('the iOS tap carries the cut in the item audio mix (I26)', () {
      expect(navisReplayGainInPipeline(usesMpv: false, iosTap: true), isTrue);
      // No tap (the EQ pipeline is gone): the Dart cut through volume stays.
      expect(navisReplayGainInPipeline(usesMpv: false, iosTap: false), isFalse);
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
          for (final preamp in [-6.0, 0.0, 6.0, 8.0]) {
            for (final untagged in [-8.0, 0.0]) {
              final levels = replayGainLevels(
                limiterSupported: preamp > 4,
                mode: mode,
                loudness: ReplayGainLoudness.custom,
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
