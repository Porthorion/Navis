// ReplayGain boost for the iOS tap (I24): the pure timing decision and the
// click-free gain ramp. AVPlayer.volume stops at 1.0, so a boost has to be a
// gain stage in the tap, after the EQ and pitch. The cut is the volume of the
// item's own audio mix (I26), and a song never gets both. Pure C11, no platform dependencies, so the same
// file is unit-tested on any host (see darwin/test/navis_boost_test.c).
#ifndef NAVIS_BOOST_H
#define NAVIS_BOOST_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The most a song is ever turned up (Dart's replayGainMaxBoostDb), in dB and as a gain.
#define NAVIS_BOOST_MAX_DB 12.0
#define NAVIS_BOOST_MAX_LINEAR 3.98107171f
/// The last stretch of a song, in wall-clock ms, in which the pipeline may already
/// hold its successor's samples (Dart's replayGainBoostGuardWindowMs).
#define NAVIS_BOOST_GUARD_WINDOW_MS 3000

typedef struct {
    double ownDb;            // the playing song's boost; NaN or negative is 0
    double nextDb;           // the next song's boost; NaN means there is none
    double positionMs;       // media ms into the song; NaN when unknown
    double playerDurationMs; // AVPlayer's duration; NaN, infinite or 0 when unknown
    double tagDurationMs;    // the song tag's duration, sent with the boost map; NaN or 0 when unknown
    double speed;            // playback rate; 0, negative or NaN count as 1
    bool latched;            // the song was guarded before and stays guarded
    bool held;               // a rise is held back (a song event happened < 500 ms ago)
    double previousDb;       // the target in force; the bound while latched or held
} NavisBoostInput;

typedef struct {
    double targetDb;    // 0..12
    bool guarded;       // the target may be lowered for the next song
    bool latched;       // guarded with known timing: store as the next input's `latched` until the next song event
} NavisBoostOutput;

/// Main thread, no side effects. The song's duration is the smaller of the player's and the tag's
/// that are known (AVPlayer's can be wrong for a VBR MP3 without a Xing header or a stream),
/// so the smaller remaining time wins. In the last
/// `windowMs` of wall-clock time (media time over speed), for songs shorter than
/// the window plus 1 s and when the timing is unknown, the target is the lower of
/// the two songs' boosts; once guarded by the clock a song stays guarded and its target only
/// goes down (unknown timing guards without latching). While held the target is also min(previous, new): a drop applies at
/// once, a rise waits.
void navis_boost_decide(const NavisBoostInput *in, int windowMs, NavisBoostOutput *out);

/// The gain a boost of `db` is: never a cut, never beyond 12 dB, NaN is none. Not realtime (pow).
float navis_boost_linear(double db);

/// The volume of a ReplayGain cut of `db` as the per-item audio mix applies it (I26): `10^(db/20)`,
/// never above 1 and never below -60 dB (0.001). NaN (an unstamped item, radio), infinities and
/// db >= 0 leave the item alone (1). Not realtime (pow); used by the player's attach, re-assign and
/// diagnostics so all three agree.
float navis_replaygain_cut_linear(double db);

/// A per-slot gain with a linear 20 ms ramp, owned by the render thread. Linear in
/// gain, like Android's BoostRamp.
typedef struct {
    int rampFrames;
    float gain, target, start, step; // gain = start + step * k on frame k of a ramp, so no error accumulates
    int remaining;
    bool primed; // false until the first block: that one snaps to its target
} NavisBoostRamp;

void navis_boost_ramp_init(NavisBoostRamp *r, int sampleRate);
/// Jumps to `target` (clamped as in process) with no ramp.
void navis_boost_ramp_snap(NavisBoostRamp *r, float target);
/// Realtime: no allocation, locks or pow. In place, non-interleaved float, after
/// ramping to `target` (clamped to 1..NAVIS_BOOST_MAX_LINEAR, NaN is 1). Samples
/// beyond full scale after a gain above 1 add to `*clipCount`; they are not limited.
void navis_boost_ramp_process(NavisBoostRamp *r, float *const *channels, int count, int frames, float target,
                              uint64_t *clipCount);

#ifdef __cplusplus
}
#endif
#endif
