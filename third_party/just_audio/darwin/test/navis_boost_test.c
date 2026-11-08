// Host-side tests for NavisBoost.c (iOS ReplayGain boost, I24): the pure timing
// decision (a C port of Dart's guardedBoostDb plus the hold) and the click-free
// gain ramp. Run by tool/equalizer_native_test.sh under ASan/UBSan.
#include "../just_audio/Sources/just_audio/NavisBoost.h"

#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RATE 44100
#define RAMP 882 /* 20 ms at 44.1 kHz */
#define TEN_DB 3.16227766f
#define MAX_FRAMES 4096

static void fail(const char *context, double expected, double actual) {
    fprintf(stderr, "FAIL %s: expected %g, received %g\n", context, expected, actual);
    exit(1);
}

static void check(bool ok, const char *context) {
    if (!ok) fail(context, 1, 0);
}

static void near(double actual, double expected, double tolerance, const char *context) {
    if (!isfinite(actual) || fabs(actual - expected) > tolerance) fail(context, expected, actual);
}

// MARK: decide

// Defaults mirror guarded() in replay_gain_db_test.dart: own 8, next 3, 2 s left of 180 s at speed 1
// (the player's duration; the tag's is unknown).
static NavisBoostInput input(void) {
    return (NavisBoostInput){
        .ownDb = 8, .nextDb = 3, .positionMs = 178000, .playerDurationMs = 180000, .tagDurationMs = NAN, .speed = 1,
        .latched = false, .held = false, .previousDb = 0,
    };
}

// `remaining` ms left of the player's duration.
static void setRemaining(NavisBoostInput *in, double remaining) { in->positionMs = in->playerDurationMs - remaining; }

static NavisBoostOutput decide(NavisBoostInput in) {
    NavisBoostOutput out;
    memset(&out, 0x55, sizeof out);
    navis_boost_decide(&in, NAVIS_BOOST_GUARD_WINDOW_MS, &out);
    return out;
}

static void testDecideWindow(void) {
    NavisBoostInput in = input();
    setRemaining(&in, 3001);
    near(decide(in).targetDb, 8, 0, "outside the last 3 s a song keeps its own boost");
    check(!decide(in).guarded && !decide(in).latched, "and is not guarded");
    setRemaining(&in, 120000);
    near(decide(in).targetDb, 8, 0, "far from the end too");
    in = input();
    near(decide(in).targetDb, 3, 0, "inside the window the lower of the two applies");
    check(decide(in).guarded && decide(in).latched, "guarded, and the latch is set");
    setRemaining(&in, 3000);
    near(decide(in).targetDb, 3, 0, "exactly 3000 ms is inside");
    in = input();
    in.nextDb = 12;
    near(decide(in).targetDb, 8, 0, "a louder successor never raises");
    in = input();
    in.nextDb = NAN;
    near(decide(in).targetDb, 8, 0, "no next song is the song's own boost");
    check(decide(in).guarded, "but it is still guarded (the next can be added any time)");
    in.nextDb = 8;
    near(decide(in).targetDb, 8, 0, "the same song again is its own boost");
}

static void testDecideLatch(void) {
    NavisBoostInput in = input();
    in.latched = true;
    in.previousDb = 1;
    near(decide(in).targetDb, 1, 0, "the latch only goes down");
    in.previousDb = 5;
    near(decide(in).targetDb, 3, 0, "below the latch the lower of two applies");
    in.nextDb = 12;
    in.previousDb = 6;
    near(decide(in).targetDb, 6, 0, "a louder successor never raises past the latch");
    // A latched song stays guarded after the window closes (a speed drop moves the window).
    in = input();
    in.latched = true;
    setRemaining(&in, 10000);
    in.previousDb = 1;
    near(decide(in).targetDb, 1, 0, "latched far from the end, value 1");
    in.previousDb = 5;
    near(decide(in).targetDb, 3, 0, "latched far from the end, value 5");
    check(decide(in).guarded && decide(in).latched, "still guarded and latched");
    // Not latched: the previous value is not a bound.
    in = input();
    setRemaining(&in, 10000);
    in.previousDb = 1;
    near(decide(in).targetDb, 8, 0, "an unlatched song far from the end ignores the previous value");
}

static void testDecideUnknownTiming(void) {
    NavisBoostInput in = input();
    setRemaining(&in, NAN);
    near(decide(in).targetDb, 3, 0, "an unknown position is guarded");
    check(decide(in).guarded && !decide(in).latched, "but not latched: the timing is only unknown until the item is ready");
    in = input();
    in.playerDurationMs = NAN;
    setRemaining(&in, 100000);
    near(decide(in).targetDb, 3, 0, "an unknown duration is guarded");
    check(decide(in).guarded && !decide(in).latched, "and not latched either");
    in = input();
    in.playerDurationMs = 3999;
    setRemaining(&in, 3500);
    near(decide(in).targetDb, 3, 0, "a song shorter than window + 1 s is guarded from its start");
    check(decide(in).latched, "a short song with a known length latches");
    in.playerDurationMs = 4000;
    near(decide(in).targetDb, 8, 0, "4 s is long enough: 3.5 s left is outside the window");
    in.playerDurationMs = INFINITY;
    setRemaining(&in, 100000);
    near(decide(in).targetDb, 3, 0, "an infinite duration (a stream) is unknown");
}

static void testDecideSpeed(void) {
    NavisBoostInput in = input();
    setRemaining(&in, 5000);
    in.speed = 1;
    near(decide(in).targetDb, 8, 0, "5 s of media at speed 1 is outside");
    in.speed = 2;
    near(decide(in).targetDb, 3, 0, "at speed 2 it is 2.5 s of wall clock: inside");
    in.speed = 0;
    near(decide(in).targetDb, 8, 0, "a speed of 0 counts as 1");
    in.speed = -1;
    near(decide(in).targetDb, 8, 0, "a negative speed counts as 1");
    in.speed = NAN;
    near(decide(in).targetDb, 8, 0, "a NaN speed counts as 1");
}

static void testDecideHold(void) {
    NavisBoostInput in = input();
    setRemaining(&in, 100000);
    in.held = true;
    in.previousDb = 3;
    near(decide(in).targetDb, 3, 0, "while held a rise waits: min(previous, new)");
    check(!decide(in).guarded, "held is not guarded");
    in.previousDb = 10;
    near(decide(in).targetDb, 8, 0, "while held a drop applies at once");
    in.held = false;
    in.previousDb = 3;
    near(decide(in).targetDb, 8, 0, "after the hold the rise applies");
    in.held = true;
    in.previousDb = NAN;
    near(decide(in).targetDb, 0, 0, "an unknown previous value holds at 0");
}

static void testDecideClamps(void) {
    NavisBoostInput in = input();
    setRemaining(&in, 100000);
    in.ownDb = NAN;
    near(decide(in).targetDb, 0, 0, "NaN own boost is 0");
    in.ownDb = -5;
    near(decide(in).targetDb, 0, 0, "a negative own boost is 0");
    in.ownDb = 50;
    near(decide(in).targetDb, 12, 0, "never beyond 12 dB");
    in.ownDb = INFINITY;
    near(decide(in).targetDb, 12, 0, "infinity is 12 dB, not an error");
    in = input();
    in.nextDb = -1;
    near(decide(in).targetDb, 0, 0, "a negative next boost is 0 and wins inside the window");
    in.nextDb = 50;
    near(decide(in).targetDb, 8, 0, "a huge next boost is capped, own still lower");
    in = input();
    in.latched = true;
    in.previousDb = 50;
    near(decide(in).targetDb, 3, 0, "a huge previous value is capped too");
    for (int i = 0; i < 1000; i++) {
        in = input();
        in.ownDb = (i % 7 == 0) ? NAN : (i - 300) * 0.1;
        in.nextDb = (i % 5 == 0) ? NAN : (i - 500) * 0.07;
        in.previousDb = (i % 11 == 0) ? NAN : (i - 200) * 0.1;
        setRemaining(&in, (i % 13 == 0) ? NAN : i * 100.0);
        in.latched = i % 2;
        in.held = i % 3 == 0;
        NavisBoostOutput out = decide(in);
        check(out.targetDb >= 0 && out.targetDb <= 12, "the target always lies in 0..12");
    }
}


// Item 1 of the I24 fix round: AVPlayer's duration alone is wrong for a VBR MP3 without a Xing
// header or an overestimated stream, so the tag's duration comes with the map and the smaller
// remaining time wins (Android's rule).
static void testDecideTagDuration(void) {
    NavisBoostInput in = input();
    in.playerDurationMs = NAN;
    in.tagDurationMs = 180000;
    in.positionMs = 178000;
    near(decide(in).targetDb, 3, 0, "the tag alone times the guard when the player has no duration");
    check(decide(in).guarded && decide(in).latched, "and a known timing latches");
    in.positionMs = 100000;
    near(decide(in).targetDb, 8, 0, "far from the tag's end it keeps its own boost");
    // The player overestimates (180 s for a 120 s song): the tag's smaller remaining time wins.
    in = input();
    in.playerDurationMs = 180000;
    in.tagDurationMs = 120000;
    in.positionMs = 118000;
    near(decide(in).targetDb, 3, 0, "an overestimating player does not hide the last 3 s");
    // The player underestimates: it wins, an early guard only under-boosts.
    in = input();
    in.playerDurationMs = 100000;
    in.tagDurationMs = 180000;
    in.positionMs = 98000;
    near(decide(in).targetDb, 3, 0, "the smaller of the two durations wins");
    // A tag of 0 or less is no tag; no duration at all guards without latching.
    in = input();
    in.playerDurationMs = NAN;
    in.tagDurationMs = 0;
    near(decide(in).targetDb, 3, 0, "a zero tag is unknown");
    check(decide(in).guarded && !decide(in).latched, "and, with the player unknown, does not latch");
    in.tagDurationMs = NAN;
    check(decide(in).guarded && !decide(in).latched, "neither duration known: guarded, not latched");
    // A short song by the tag is guarded from its start even when the player says it is long.
    in = input();
    in.tagDurationMs = 3500;
    in.positionMs = 100;
    near(decide(in).targetDb, 3, 0, "a song the tag calls shorter than window + 1 s is guarded");
    check(decide(in).latched, "and latched");
}

// Item 4: a seek inside the playing song decides from the remaining time at the target position,
// so a seek that lands outside the window keeps the song's own boost.
static void testDecideSeekKeepsTheBoost(void) {
    NavisBoostInput in = input();
    in.ownDb = 10;
    in.nextDb = 0;
    in.playerDurationMs = 12000;
    in.tagDurationMs = 12000;
    in.positionMs = 7000;
    in.held = true;
    in.previousDb = 10;
    NavisBoostOutput out = decide(in);
    near(out.targetDb, 10, 0, "a seek to 7 s of 12 s keeps 10 dB while the hold is on");
    check(!out.guarded, "and is not guarded");
    in.positionMs = 10000;
    near(decide(in).targetDb, 0, 0, "a seek into the last 3 s takes the next song's boost");
    in.positionMs = 1000;
    in.previousDb = 0;
    near(decide(in).targetDb, 0, 0, "a seek out of the window rises only after the hold");
    in.held = false;
    near(decide(in).targetDb, 10, 0, "and then rises");
}

// MARK: ramp

static float *rampBuffer(int channels, int frames, float value) {
    float *data = malloc((size_t)channels * (size_t)frames * sizeof(float));
    check(data != NULL, "alloc");
    for (int i = 0; i < channels * frames; i++) data[i] = value;
    return data;
}

static void testRampReachesTheTargetInTwentyMs(void) {
    NavisBoostRamp r;
    navis_boost_ramp_init(&r, RATE);
    navis_boost_ramp_snap(&r, 1.0f);
    float *data = rampBuffer(1, 2 * RAMP, 1.0f);
    float *ch[1] = {data};
    uint64_t clips = 0;
    navis_boost_ramp_process(&r, ch, 1, 2 * RAMP, TEN_DB, &clips);
    float delta = TEN_DB - 1.0f;
    float previous = 1.0f;
    for (int i = 0; i < RAMP; i++) {
        check(data[i] >= previous, "the ramp is monotonic");
        check(data[i] - previous <= delta / RAMP * 1.001f + 1e-6f, "no step is larger than delta / ramp frames");
        previous = data[i];
    }
    check(data[0] > 1.0f, "the first frame already moves");
    check(data[RAMP - 2] < TEN_DB, "frame 880 is not there yet");
    check(data[RAMP - 1] == TEN_DB, "the 882nd frame, 20 ms in, is exactly the target");
    for (int i = RAMP; i < 2 * RAMP; i++) check(data[i] == TEN_DB, "and it stays there");
    // The same target again does not restart the ramp.
    float *more = rampBuffer(1, 64, 1.0f);
    float *ch2[1] = {more};
    navis_boost_ramp_process(&r, ch2, 1, 64, TEN_DB, &clips);
    for (int i = 0; i < 64; i++) check(more[i] == TEN_DB, "an unchanged target keeps its gain");
    free(more);
    free(data);
}

static void testRampDownIsClickFreeToo(void) {
    NavisBoostRamp r;
    navis_boost_ramp_init(&r, 48000); // 960 frames
    navis_boost_ramp_snap(&r, TEN_DB);
    float *data = rampBuffer(1, 2000, 1.0f);
    float *ch[1] = {data};
    uint64_t clips = 0;
    navis_boost_ramp_process(&r, ch, 1, 2000, 1.0f, &clips);
    float previous = TEN_DB;
    for (int i = 0; i < 960; i++) {
        check(data[i] <= previous, "a drop is monotonic");
        check(previous - data[i] <= (TEN_DB - 1.0f) / 960 * 1.001f + 1e-6f, "and steps no more than delta / 960");
        previous = data[i];
    }
    check(data[959] == 1.0f && data[1999] == 1.0f, "it lands exactly on unity");
    free(data);
}

static void testRampRetargetMidwayHasNoJump(void) {
    NavisBoostRamp r;
    navis_boost_ramp_init(&r, RATE);
    navis_boost_ramp_snap(&r, 1.0f);
    float *data = rampBuffer(1, 3 * RAMP, 1.0f);
    float *ch[1] = {data};
    uint64_t clips = 0;
    navis_boost_ramp_process(&r, ch, 1, 300, TEN_DB, &clips);
    float atSwitch = data[299];
    float *rest = data + 300;
    float *ch2[1] = {rest};
    navis_boost_ramp_process(&r, ch2, 1, 3 * RAMP - 300, 1.0f, &clips);
    check(fabsf(rest[0] - atSwitch) <= (atSwitch - 1.0f) / RAMP * 1.001f + 1e-6f, "reversing midway steps at most delta / ramp frames");
    check(rest[3 * RAMP - 301] == 1.0f, "and arrives at the new target");
    free(data);
}

static void testRampSplitBlocksAgree(void) {
    float *a = rampBuffer(2, 3000, 0.25f);
    float *b = rampBuffer(2, 3000, 0.25f);
    float *chA[2] = {a, a + 3000};
    float *chB1[2] = {b, b + 3000};
    NavisBoostRamp x, y;
    navis_boost_ramp_init(&x, RATE);
    navis_boost_ramp_init(&y, RATE);
    navis_boost_ramp_snap(&x, 1.0f);
    navis_boost_ramp_snap(&y, 1.0f);
    uint64_t cx = 0, cy = 0;
    navis_boost_ramp_process(&x, chA, 2, 3000, TEN_DB, &cx);
    // Same signal in blocks of 1000 (channel pointers advance).
    for (int off = 0; off < 3000; off += 1000) {
        float *p[2] = {chB1[0] + off, chB1[1] + off};
        navis_boost_ramp_process(&y, p, 2, 1000, TEN_DB, &cy);
    }
    check(memcmp(a, b, 2 * 3000 * sizeof(float)) == 0, "the same samples whatever the block size");
    for (int i = 0; i < 3000; i++) check(a[i] == a[3000 + i], "every channel gets the same gain at a frame");
    free(a);
    free(b);
}

static void testRampSnapIsImmediate(void) {
    NavisBoostRamp r;
    navis_boost_ramp_init(&r, RATE);
    navis_boost_ramp_snap(&r, TEN_DB);
    float *data = rampBuffer(2, 128, 0.1f);
    float *ch[2] = {data, data + 128};
    uint64_t clips = 0;
    navis_boost_ramp_process(&r, ch, 2, 128, TEN_DB, &clips);
    for (int i = 0; i < 256; i++) check(data[i] == 0.1f * TEN_DB, "a snapped ramp is at the target from the first frame");
    navis_boost_ramp_snap(&r, 1.0f);
    float *more = rampBuffer(1, 16, 0.5f);
    float *ch2[1] = {more};
    navis_boost_ramp_process(&r, ch2, 1, 16, 1.0f, &clips);
    for (int i = 0; i < 16; i++) check(more[i] == 0.5f, "and snapping down is immediate");
    free(more);
    free(data);
}

static void testRampFirstBlockOfAFreshRampSnaps(void) {
    NavisBoostRamp r;
    navis_boost_ramp_init(&r, RATE); // never snapped: a slot's first block
    float *data = rampBuffer(1, 64, 0.1f);
    float *ch[1] = {data};
    uint64_t clips = 0;
    navis_boost_ramp_process(&r, ch, 1, 64, TEN_DB, &clips);
    for (int i = 0; i < 64; i++) check(data[i] == 0.1f * TEN_DB, "a fresh ramp starts at its first target, not at unity");
    free(data);
}

static void testRampUnityIsBitExact(void) {
    NavisBoostRamp r;
    navis_boost_ramp_init(&r, RATE);
    navis_boost_ramp_snap(&r, 1.0f);
    float *data = malloc(2 * 1000 * sizeof(float));
    for (int i = 0; i < 2000; i++) data[i] = (float)sin(0.01 * i) * (i % 3 == 0 ? 1.7f : 0.9f); // some above 1.0
    float *copy = malloc(2 * 1000 * sizeof(float));
    memcpy(copy, data, 2 * 1000 * sizeof(float));
    float *ch[2] = {data, data + 1000};
    uint64_t clips = 0;
    navis_boost_ramp_process(&r, ch, 2, 1000, 1.0f, &clips);
    check(memcmp(data, copy, 2 * 1000 * sizeof(float)) == 0, "target 1.0 is a bit-exact passthrough");
    check(clips == 0, "and counts nothing: only gain above 1 can clip");
    free(copy);
    free(data);
}

static void testRampClipCount(void) {
    NavisBoostRamp r;
    navis_boost_ramp_init(&r, RATE);
    navis_boost_ramp_snap(&r, TEN_DB);
    float *data = rampBuffer(2, 100, 0.5f);
    float *ch[2] = {data, data + 100};
    uint64_t clips = 7; // the caller's running count
    navis_boost_ramp_process(&r, ch, 2, 100, TEN_DB, &clips);
    check(clips == 7 + 200, "0.5 x 3.162 counts every sample");
    // The samples are not limited: the counter only counts.
    near(data[0], 0.5f * TEN_DB, 1e-6, "a clipped sample is not changed");
    for (int i = 0; i < 200; i++) data[i] = 0.3f;
    navis_boost_ramp_process(&r, ch, 2, 100, TEN_DB, &clips);
    check(clips == 7 + 200, "0.3 x 3.162 is under 1.0 and counts nothing");
    for (int i = 0; i < 200; i++) data[i] = -0.5f;
    navis_boost_ramp_process(&r, ch, 2, 100, TEN_DB, &clips);
    check(clips == 7 + 400, "negative peaks count too");
    free(data);
}

// Output of a ramp that has run `frames` frames towards `target`, from a snapped unity start, on 0.01.
static float rampedValue(float target, int frames) {
    NavisBoostRamp r;
    navis_boost_ramp_init(&r, RATE);
    navis_boost_ramp_snap(&r, 1.0f);
    float *data = rampBuffer(1, frames, 0.01f);
    float *ch[1] = {data};
    uint64_t clips = 0;
    navis_boost_ramp_process(&r, ch, 1, frames, target, &clips);
    float last = data[frames - 1];
    free(data);
    return last;
}

static void testRampClampsTheTarget(void) {
    near(rampedValue(100.0f, 4 * RAMP) / 0.01f, NAVIS_BOOST_MAX_LINEAR, 1e-5, "a target beyond 12 dB stops at 12 dB");
    check(rampedValue(0.25f, 4 * RAMP) == 0.01f, "a target below unity (a cut) is unity");
    check(rampedValue(NAN, 4 * RAMP) == 0.01f, "NaN is unity");
    check(rampedValue(INFINITY, 4 * RAMP) / 0.01f < NAVIS_BOOST_MAX_LINEAR * 1.00001f, "infinity is 12 dB");
}

static void testRampRateSetsTheLength(void) {
    int rates[] = {8000, 22050, 44100, 48000, 96000, 192000};
    for (int k = 0; k < 6; k++) {
        NavisBoostRamp r;
        navis_boost_ramp_init(&r, rates[k]);
        navis_boost_ramp_snap(&r, 1.0f);
        int frames = rates[k] / 50 + 5;
        float *data = rampBuffer(1, frames, 1.0f);
        float *ch[1] = {data};
        uint64_t clips = 0;
        navis_boost_ramp_process(&r, ch, 1, frames, TEN_DB, &clips);
        check(data[rates[k] / 50 - 1] == TEN_DB, "the ramp is 20 ms at every rate");
        check(rates[k] / 50 < 2 || data[rates[k] / 50 - 2] < TEN_DB, "and not shorter");
        free(data);
    }
}

// The control thread writes the target as one atomic float; it has to be lock-free.
static void testTargetAtomicIsLockFree(void) {
    _Atomic float probe;
    atomic_init(&probe, 1.0f);
    check(atomic_is_lock_free(&probe), "an atomic float is lock-free on this target");
}

typedef struct {
    const char *name;
    void (*run)(void);
} Test;

int main(void) {
    static const Test tests[] = {
        {"decideWindow", testDecideWindow},
        {"decideLatch", testDecideLatch},
        {"decideUnknownTiming", testDecideUnknownTiming},
        {"decideSpeed", testDecideSpeed},
        {"decideHold", testDecideHold},
        {"decideClamps", testDecideClamps},
        {"decideTagDuration", testDecideTagDuration},
        {"decideSeekKeepsTheBoost", testDecideSeekKeepsTheBoost},
        {"rampReachesTheTargetInTwentyMs", testRampReachesTheTargetInTwentyMs},
        {"rampDownIsClickFreeToo", testRampDownIsClickFreeToo},
        {"rampRetargetMidwayHasNoJump", testRampRetargetMidwayHasNoJump},
        {"rampSplitBlocksAgree", testRampSplitBlocksAgree},
        {"rampSnapIsImmediate", testRampSnapIsImmediate},
        {"rampFirstBlockOfAFreshRampSnaps", testRampFirstBlockOfAFreshRampSnaps},
        {"rampUnityIsBitExact", testRampUnityIsBitExact},
        {"rampClipCount", testRampClipCount},
        {"rampClampsTheTarget", testRampClampsTheTarget},
        {"rampRateSetsTheLength", testRampRateSetsTheLength},
        {"targetAtomicIsLockFree", testTargetAtomicIsLockFree},
    };
    for (size_t i = 0; i < sizeof tests / sizeof *tests; i++) tests[i].run();
    puts("Navis Darwin boost: decision table, click-free ramp, clip count and clamps passed.");
    return 0;
}
