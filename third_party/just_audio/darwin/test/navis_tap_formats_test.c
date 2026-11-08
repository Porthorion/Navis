// Host-side fixtures for NavisTapFormats.c (iOS one tap stream per audio format,
// I25) with a fake pitch AU: a delay of LAT frames times a marker gain, so every
// expectation is exact. The real equalizer stream runs at -12 dB, so "processed"
// shows as a level change and "dry" as bit-exact. Run by
// tool/equalizer_native_test.sh under ASan/UBSan; the concurrency tests alone
// (argv "--concurrency") also under TSan on macOS.
#include "../just_audio/Sources/just_audio/NavisTapFormats.h"

#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LAT 256
#define GAIN 0.5f
#define MAX_FRAMES 8208
#define EQ12 0.25118864f /* -12 dB */
#define EQ6 0.50118723f  /* -6 dB */

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

// MARK: fake pitch AU

typedef struct {
    int rate, channels;
    int pos;
    float line[8][LAT];
    float lastCents;
    _Atomic int centsCalls;
    _Atomic uint64_t renders;
} Fake;

static _Atomic int g_creates, g_destroys, g_wrongRate;
static _Thread_local int t_blockRate; // the rate of the block this thread is processing, 0 outside
static Fake *g_aus[64];                // the first 64 by creation order; NULL once destroyed (control thread only)
static int g_nAus;
static bool g_failCreate;
// Armed: the next render of any fake AU starts another process call on the same
// set from inside it, the way a second render thread would find the slot busy.
static struct {
    NavisTapFormats *t;
    int armed;
} g_reenter;

static int fakeRender(void *user, const float *const *in, float *const *out, int channels, int frames) {
    Fake *f = user;
    atomic_fetch_add(&f->renders, 1);
    if (g_reenter.armed) {
        g_reenter.armed = 0;
        float nested[2][128] = {{0}};
        float *nch[2] = {nested[0], nested[1]};
        navis_tap_formats_process(g_reenter.t, true, 0, 128, 44100, nch, 2, 128);
    }
    if (t_blockRate && f->rate != t_blockRate) atomic_fetch_add(&g_wrongRate, 1);
    for (int i = 0; i < frames; i++) {
        for (int c = 0; c < channels; c++) {
            out[c][i] = GAIN * f->line[c][(f->pos + i) % LAT];
            f->line[c][(f->pos + i) % LAT] = in[c][i];
        }
    }
    f->pos = (f->pos + frames) % LAT;
    return 0;
}

static void fakeReset(void *user) {
    Fake *f = user;
    memset(f->line, 0, sizeof f->line);
    f->pos = 0;
}

static void fakeCents(void *user, float cents) {
    Fake *f = user;
    f->lastCents = cents;
    atomic_fetch_add(&f->centsCalls, 1);
}

static void *fakeCreate(double rate, int channels, int maxFrames, NavisPitchRenderer *out) {
    (void)maxFrames;
    if (g_failCreate) return NULL;
    Fake *f = calloc(1, sizeof *f);
    f->rate = (int)lround(rate);
    f->channels = channels;
    *out = (NavisPitchRenderer){f, fakeRender, fakeReset, fakeCents, LAT};
    if (g_nAus < 64) g_aus[g_nAus++] = f; // only the first few are ever inspected
    atomic_fetch_add(&g_creates, 1);
    return f;
}

static void fakeDestroy(void *au) {
    for (int i = 0; i < g_nAus; i++)
        if (g_aus[i] == au) g_aus[i] = NULL;
    free(au);
    atomic_fetch_add(&g_destroys, 1);
}

static uint64_t fakeMismatches(const void *au) {
    (void)au;
    return 0;
}

// MARK: helpers

static NavisEqConfig config(double preampDb) {
    NavisEqConfig c;
    memset(&c, 0, sizeof c);
    c.enabled = true;
    c.preamp = preampDb;
    return c;
}

static NavisTapFormats *newSet(double preampDb, int32_t cents) {
    atomic_store(&g_creates, 0);
    atomic_store(&g_destroys, 0);
    atomic_store(&g_wrongRate, 0);
    memset(g_aus, 0, sizeof g_aus);
    g_nAus = 0;
    g_failCreate = false;
    g_reenter.armed = 0;
    NavisEqConfig c = config(preampDb);
    NavisPitchFactory factory = {fakeCreate, fakeDestroy, fakeMismatches};
    NavisTapFormats *t = navis_tap_formats_new(&c, cents, factory);
    check(t != NULL, "set created");
    return t;
}

static void freeSet(NavisTapFormats *t) {
    navis_tap_formats_free(t);
    check(atomic_load(&g_creates) == atomic_load(&g_destroys), "every fake AU is destroyed");
}

static NavisTapFormatsState state(NavisTapFormats *t) {
    NavisTapFormatsState s;
    navis_tap_formats_state(t, &s);
    return s;
}

static bool prepare(NavisTapFormats *t, int rate, int channels) {
    return navis_tap_formats_prepare(t, rate, channels, rate > 50000 ? MAX_FRAMES : 4096, true);
}

// Deterministic non-periodic input, peak 0.8.
static float sample(int channel, long k) {
    return (float)(0.8 * sin(0.013 * (double)k * (1.0 + 1e-6 * (double)k) + channel));
}

typedef struct {
    float in[8][MAX_FRAMES], out[8][MAX_FRAMES];
} Block;

// One block of `frames` frames at `rate` on a `timescale` clock, input from index k0.
static void runBlockAt(NavisTapFormats *t, Block *b, int rate, int32_t timescale, int channels, int frames,
                       bool start, uint32_t generation, long k0, int64_t value) {
    float *ch[8];
    for (int c = 0; c < channels; c++) {
        for (int i = 0; i < frames; i++) b->out[c][i] = b->in[c][i] = sample(c, k0 + i);
        ch[c] = b->out[c];
    }
    t_blockRate = rate;
    navis_tap_formats_process(t, start, generation, value, timescale, ch, channels, frames);
    t_blockRate = 0;
}

// The block's duration as CMTime rounds it: whole ticks of 1/timescale.
static int64_t ticks(int frames, int rate, int32_t timescale) {
    return (int64_t)llround((double)frames * (double)timescale / (double)rate);
}

static void runBlock(NavisTapFormats *t, Block *b, int rate, int channels, int frames, bool start,
                     uint32_t generation, long k0) {
    runBlockAt(t, b, rate, rate, channels, frames, start, generation, k0, frames);
}

static bool isDry(const Block *b, int channels, int frames) {
    for (int c = 0; c < channels; c++)
        if (memcmp(b->in[c], b->out[c], (size_t)frames * sizeof(float)) != 0) return false;
    return true;
}

// out = ratio * in from frame `from`.
static bool isScaled(const Block *b, int channels, int frames, float ratio, int from) {
    for (int c = 0; c < channels; c++)
        for (int i = from; i < frames; i++)
            if (fabsf(b->out[c][i] - ratio * b->in[c][i]) > 2e-6f) return false;
    return true;
}

static const NavisTapFormatInfo *infoFor(const NavisTapFormatsState *s, int rate, int channels) {
    for (int i = 0; i < s->slotCount; i++)
        if (s->formats[i].sampleRate == rate && s->formats[i].channels == channels) return &s->formats[i];
    return NULL;
}

// MARK: 1. the block's format decides the stream

static void testFormatFollowsTheBlock(void) {
    static Block b;
    NavisTapFormats *t = newSet(-12, 0);
    long k = 0;
    // Two pipelines are prepared before the first one plays (preroll of the next song).
    check(prepare(t, 22050, 2) && prepare(t, 48000, 2), "two formats prepared");
    for (int i = 0; i < 4; i++, k += 4096) {
        runBlock(t, &b, 22050, 2, 4096, i == 0, 0, k);
        check(isScaled(&b, 2, 4096, EQ12, 0), "22050 blocks come out at -12 dB");
    }
    NavisTapFormatsState s = state(t);
    check(s.hasStream && s.stream.sampleRate == 22050, "the 22050 song runs at the 22050 stream");
    near(s.stream.levelDeltaDb, -12, 0.1, "level delta of the 22050 song");
    check(navis_tap_formats_unprepare(t), "first pipeline ended");
    for (int i = 0; i < 4; i++, k += 4096) {
        runBlock(t, &b, 48000, 2, 4096, i == 0, 0, k);
        check(isScaled(&b, 2, 4096, EQ12, 0), "48000 blocks come out at -12 dB after the first unprepare");
    }
    s = state(t);
    check(s.hasStream && s.stream.sampleRate == 48000, "the 48000 song runs at the 48000 stream");
    check(prepare(t, 96000, 2), "third format prepared");
    check(navis_tap_formats_unprepare(t), "second pipeline ended");
    for (int i = 0; i < 4; i++, k += 8208) {
        runBlock(t, &b, 96000, 2, 8208, i == 0, 0, k);
        check(isScaled(&b, 2, 8208, EQ12, 0), "96000 blocks come out at -12 dB, the last pipeline included");
    }
    s = state(t);
    check(s.hasStream && s.stream.sampleRate == 96000, "the 96000 song runs at the 96000 stream");
    near(s.stream.levelDeltaDb, -12, 0.1, "level delta of the 96000 song");
    check(s.slotCount == 3 && s.prepareCalls == 3 && s.livePipelines == 1, "three formats, three pipelines, one live");
    for (int i = 0; i < 3; i++) check(s.formats[i].processedFrames > 0, "every format processed frames");
    check(infoFor(&s, 22050, 2)->processedFrames == 4 * 4096 && infoFor(&s, 96000, 2)->processedFrames == 4 * 8208,
          "each format counts its own frames");
    check(s.unmatchedFrames == 0 && s.overlapBlocks == 0, "nothing unmatched");
    check(s.processedFrames == 4 * 4096 * 2 + 4 * 8208, "the total is the sum over formats");
    navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 2. a held format is reused untouched

static void testReuseKeepsTheSlot(void) {
    static Block b;
    NavisTapFormats *t = newSet(-12, 700); // pitch on: the fake's delay line is the history
    long k = 0;
    check(prepare(t, 44100, 2) && prepare(t, 44100, 2), "same format twice");
    for (int i = 0; i < 3; i++, k += 1024) runBlock(t, &b, 44100, 2, 1024, i == 0, 0, k);
    uint64_t frames = state(t).formats[0].processedFrames;
    check(navis_tap_formats_unprepare(t) && navis_tap_formats_unprepare(t), "both ended");
    NavisTapFormatsState s = state(t);
    check(s.slotCount == 1 && s.livePipelines == 0, "one slot, nothing live");
    check(atomic_load(&g_creates) == 1 && atomic_load(&g_destroys) == 0, "unprepare frees nothing");
    check(s.formats[0].processedFrames == frames, "the history survives");
    check(prepare(t, 44100, 2), "prepared again");
    check(atomic_load(&g_creates) == 1, "the held slot is reused, not rebuilt");
    runBlock(t, &b, 44100, 2, 1024, false, 0, k);
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < 1024; i++)
            near(b.out[c][i], EQ12 * GAIN * sample(c, k + i - LAT), 2e-6, "the delay line carries on after the re-prepare");
    s = state(t);
    check(s.resetCount == 0 && s.pitchResetCount == 0, "a re-prepare is not a reset");
    navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 3. all slots are freed only at the cap

static void fillCap(NavisTapFormats *t, Block *b, int pipelinesLeftLive) {
    for (int i = 0; i < NAVIS_TAP_MAX_FORMATS; i++) {
        int rate = 8000 + 1000 * i;
        check(prepare(t, rate, 2), "a format up to the cap is prepared");
        runBlock(t, b, rate, 2, 1024, true, 0, 0);
        check(isScaled(b, 2, 1024, EQ12, 0), "each format processes");
    }
    for (int i = 0; i < NAVIS_TAP_MAX_FORMATS - pipelinesLeftLive; i++) navis_tap_formats_unprepare(t);
}

static void testFreeAllOnlyAtTheCap(void) {
    static Block b;
    NavisTapFormats *t = newSet(-12, 0);
    fillCap(t, &b, 0);
    NavisTapFormatsState before = state(t);
    check(before.slotCount == 16 && before.livePipelines == 0 && atomic_load(&g_creates) == 16 && atomic_load(&g_destroys) == 0,
          "16 slots, none freed by 16 unprepares");
    check(prepare(t, 44100, 2), "the 17th format is prepared when no pipeline is live");
    check(atomic_load(&g_destroys) == 16 && atomic_load(&g_creates) == 17, "16 destroys, then the new slot");
    NavisTapFormatsState after = state(t);
    check(after.slotCount == 1 && after.formats[0].sampleRate == 44100, "only the new slot is held");
    check(after.processedFrames == before.processedFrames && after.resetCount >= before.resetCount,
          "the totals stay monotonic across the free-all");
    runBlock(t, &b, 44100, 2, 1024, true, 0, 0);
    check(isScaled(&b, 2, 1024, EQ12, 0), "the new slot processes");
    check(state(t).processedFrames == before.processedFrames + 1024, "and adds to the retired totals");
    navis_tap_formats_unprepare(t);
    freeSet(t);

    // With a pipeline live the 17th plays dry, with the reason.
    t = newSet(-12, 0);
    fillCap(t, &b, 1);
    check(state(t).livePipelines == 1, "one pipeline is still live");
    check(!prepare(t, 44100, 2), "the 17th format has no slot while another pipeline is live");
    check(atomic_load(&g_destroys) == 0 && atomic_load(&g_creates) == 16 && state(t).slotCount == 16,
          "nothing was freed under a live pipeline");
    runBlock(t, &b, 44100, 2, 1024, true, 0, 0);
    check(isDry(&b, 2, 1024), "its blocks pass bit-exact");
    NavisTapFormatsState s = state(t);
    check(s.unmatchedFrames == 1024, "and count as unmatched");
    check(s.formatReason && strstr(s.formatReason, "Too many") && s.pitchReason, "with the reason");
    check(navis_tap_formats_unprepare(t) && navis_tap_formats_unprepare(t) && state(t).livePipelines == 0, "both ended");
    check(prepare(t, 44100, 2) && atomic_load(&g_destroys) == 16, "with nothing live it starts over");
    check(state(t).formatReason == NULL, "and the reason is gone");
    navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 4. no read of a freed slot after a free-all

static void testStaleLastSlot(void) {
    static Block b;
    NavisTapFormats *t = newSet(-12, 0);
    check(prepare(t, 48000, 2), "first format");
    runBlock(t, &b, 48000, 2, 1024, true, 0, 0); // lastSlot = the 48000 slot
    navis_tap_formats_unprepare(t);
    for (int i = 0; i < NAVIS_TAP_MAX_FORMATS - 1; i++) {
        check(prepare(t, 9000 + 1000 * i, 2), "fill the set");
        navis_tap_formats_unprepare(t);
    }
    check(state(t).slotCount == 16, "full");
    check(prepare(t, 44100, 2), "free-all");
    NavisTapFormatsState s = state(t); // under ASan a stale lastSlot is a use-after-free
    check(s.hasStream && s.stream.sampleRate == 44100, "the state follows the new slot, not the freed one");
    runBlock(t, &b, 44100, 2, 1024, true, 0, 0);
    s = state(t);
    check(s.hasStream && s.stream.sampleRate == 44100 && s.formats[0].processedFrames == 1024, "and processes");
    navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 5. an extra unprepare

static void testExtraUnprepareIsClamped(void) {
    NavisTapFormats *t = newSet(-12, 0);
    check(!navis_tap_formats_unprepare(t), "nothing to unprepare");
    check(state(t).livePipelines == 0, "live stays 0");
    check(prepare(t, 44100, 2) && state(t).livePipelines == 1, "the next prepare counts one");
    check(navis_tap_formats_unprepare(t) && !navis_tap_formats_unprepare(t) && state(t).livePipelines == 0, "and one extra is clamped");
    NavisTapFormatsState s = state(t);
    check(s.prepareCalls == 1 && s.unprepareCalls == 3 && s.clampedUnprepares == 2,
          "every call is counted, and the unprepares that matched nothing");
    freeSet(t);
}

// MARK: 6. which slot a block goes to

static void testMatching(void) {
    static Block b;
    // Several slots: a block nobody prepared, or with another channel count, passes dry.
    NavisTapFormats *t = newSet(-12, 0);
    check(prepare(t, 48000, 2) && prepare(t, 96000, 2), "48000 and 96000");
    runBlock(t, &b, 22050, 2, 4096, true, 0, 0);
    check(isDry(&b, 2, 4096), "a 22050 block passes bit-exact");
    runBlock(t, &b, 48000, 3, 4096, true, 0, 0);
    check(isDry(&b, 3, 4096), "a 3-buffer block passes bit-exact");
    NavisTapFormatsState s = state(t);
    check(s.unmatchedFrames == 8192, "and both count as unmatched");
    // An invalid range has no rate (the first block of every pipeline): it goes to the
    // slot of the latest prepare, here 96000, whatever rate the block really has.
    runBlockAt(t, &b, 48000, 48000, 2, 4096, true, 0, 0, 0);
    check(isScaled(&b, 2, 4096, EQ12, 0) && state(t).unmatchedFrames == 8192, "an invalid range uses the latest prepared slot");
    check(state(t).formats[0].processedFrames == 0 && state(t).formats[1].processedFrames == 4096, "and only that slot");
    runBlock(t, &b, 48000, 2, 4096, true, 0, 0);
    check(isScaled(&b, 2, 4096, EQ12, 0), "the next block of audio is processed");
    navis_tap_formats_unprepare(t);
    navis_tap_formats_unprepare(t);
    freeSet(t);

    // 44.1 against 48 kHz and 88.2 against 96 kHz stay apart.
    t = newSet(-12, 0);
    static const int rates[] = {44100, 48000, 88200, 96000};
    for (int i = 0; i < 4; i++) check(prepare(t, rates[i], 2), "prepared");
    for (int round = 0; round < 2; round++)
        for (int i = 0; i < 4; i++) {
            uint64_t before = state(t).formats[i].processedFrames;
            runBlock(t, &b, rates[i], 2, 4096, round == 0, 0, 4096L * round);
            check(isScaled(&b, 2, 4096, EQ12, 0), "processed");
            check(state(t).formats[i].processedFrames == before + 4096, "by its own slot");
        }
    check(state(t).unmatchedFrames == 0, "none unmatched");
    for (int i = 0; i < 4; i++) navis_tap_formats_unprepare(t);
    freeSet(t);

    // A coarse clock rounds a short block's duration to a few ticks.
    static const int32_t scales[] = {600, 90000};
    static const int sizes[] = {4096, 136};
    static const int hz[] = {48000, 96000};
    t = newSet(-12, 0);
    check(prepare(t, 48000, 2) && prepare(t, 96000, 2), "48000 and 96000");
    for (int sc = 0; sc < 2; sc++)
        for (int sz = 0; sz < 2; sz++)
            for (int r = 0; r < 2; r++) {
                int slot = r;
                // The song starts on its own clock (that is what a song that plays stays on).
                runBlock(t, &b, hz[r], 2, 1024, false, 0, 0);
                uint64_t before = state(t).formats[slot].processedFrames;
                runBlockAt(t, &b, hz[r], scales[sc], 2, sizes[sz], sc == 0 && sz == 0, 0, 0, ticks(sizes[sz], hz[r], scales[sc]));
                check(isScaled(&b, 2, sizes[sz], EQ12, 0), "processed on a coarse clock");
                check(state(t).formats[slot].processedFrames == before + (uint64_t)sizes[sz], "by the slot of its own rate");
            }
    check(state(t).unmatchedFrames == 0, "none unmatched on a coarse clock");
    navis_tap_formats_unprepare(t);
    navis_tap_formats_unprepare(t);
    freeSet(t);

    // One slot: any rate and an invalid range still use it (today's behaviour);
    // another channel count does not.
    t = newSet(-12, 0);
    check(prepare(t, 48000, 2), "48000 only");
    runBlock(t, &b, 22050, 2, 1024, true, 0, 0);
    check(isScaled(&b, 2, 1024, EQ12, 0), "a block of another rate uses the only slot");
    runBlockAt(t, &b, 22050, 22050, 2, 1024, false, 0, 0, 0);
    check(isScaled(&b, 2, 1024, EQ12, 0), "an invalid range uses it too");
    runBlock(t, &b, 48000, 3, 1024, false, 0, 0);
    check(isDry(&b, 3, 1024) && state(t).unmatchedFrames == 1024, "a 3-buffer block does not");
    navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 7. reset rules with two pipelines

static void testInterleavedStartAndFlush(void) {
    static Block b;
    NavisTapFormats *t = newSet(-12, 700); // pitch on: wet from a fresh or reset stage's first frame
    long kA = 0, kB = 0;
    check(prepare(t, 44100, 2) && prepare(t, 48000, 2), "A and B (preroll)");
    for (int i = 0; i < 4; i++, kA += 1024) runBlock(t, &b, 44100, 2, 1024, i == 0, 0, kA);
    // B's first audio block carries B's StartOfStream, at B's rate.
    runBlock(t, &b, 48000, 2, 1024, true, 0, kB);
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < 1024; i++)
            near(b.out[c][i], i < LAT ? 0 : EQ12 * GAIN * sample(c, kB + i - LAT), 2e-6, "a new slot is wet from its first frame");
    kB += 1024;
    NavisTapFormatsState s = state(t);
    check(infoFor(&s, 48000, 2)->resetCount == 0 && infoFor(&s, 48000, 2)->pitchResetCount == 0,
          "a fresh stream counts no reset");
    runBlock(t, &b, 44100, 2, 1024, false, 0, kA);
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < 1024; i++)
            near(b.out[c][i], EQ12 * GAIN * sample(c, kA + i - LAT), 2e-6, "B's start did not touch A's history");
    kA += 1024;
    s = state(t);
    check(infoFor(&s, 44100, 2)->resetCount == 0 && infoFor(&s, 44100, 2)->pitchResetCount == 0, "A was not reset");

    // B's pipeline ends and a new one of the same format starts while A plays.
    check(navis_tap_formats_unprepare(t), "pipeline ended");
    check(prepare(t, 48000, 2) && atomic_load(&g_creates) == 2, "same format again, same slot");
    runBlock(t, &b, 44100, 2, 1024, false, 0, kA);
    kA += 1024;
    runBlock(t, &b, 48000, 2, 1024, true, 0, kB);
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < 1024; i++)
            near(b.out[c][i], i < LAT ? 0 : EQ12 * GAIN * sample(c, kB + i - LAT), 2e-6, "a reused slot starts wet from the reset");
    kB += 1024;
    runBlock(t, &b, 44100, 2, 1024, false, 0, kA);
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < 1024; i++)
            near(b.out[c][i], EQ12 * GAIN * sample(c, kA + i - LAT), 2e-6, "A carried on through B's restart");
    kA += 1024;
    s = state(t);
    check(infoFor(&s, 48000, 2)->resetCount == 1 && infoFor(&s, 48000, 2)->pitchResetCount == 1, "B reset once");
    check(infoFor(&s, 44100, 2)->resetCount == 0 && infoFor(&s, 44100, 2)->pitchResetCount == 0, "A still not reset");

    // A flush: the slot playing resets once, the idle one that had audio at its next block.
    runBlock(t, &b, 44100, 2, 1024, false, 1, kA);
    kA += 1024;
    runBlock(t, &b, 44100, 2, 1024, false, 1, kA);
    kA += 1024;
    s = state(t);
    check(infoFor(&s, 44100, 2)->resetCount == 1 && infoFor(&s, 44100, 2)->pitchResetCount == 1, "the playing slot resets once");
    check(infoFor(&s, 48000, 2)->resetCount == 1, "the idle slot has not seen the flush yet");
    runBlock(t, &b, 48000, 2, 1024, false, 1, kB);
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < LAT; i++) near(b.out[c][i], 0, 0, "the idle slot starts clean after the flush");
    s = state(t);
    check(infoFor(&s, 48000, 2)->resetCount == 2 && infoFor(&s, 48000, 2)->pitchResetCount == 2, "and resets once at its next block");
    check(infoFor(&s, 44100, 2)->resetCount == 1, "A did not reset again");
    check(s.resetCount == 3 && s.pitchResetCount == 3, "the totals add up");
    navis_tap_formats_unprepare(t);
    navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 8. configuration and pitch reach every slot

static void testFanOut(void) {
    static Block b;
    NavisTapFormats *t = newSet(-12, 0);
    check(prepare(t, 44100, 2) && prepare(t, 48000, 2), "A and B");
    NavisEqConfig c = config(-6);
    navis_tap_formats_configure(t, &c);
    long k[3] = {0, 0, 0};
    static const int rates[] = {44100, 48000};
    for (int round = 0; round < 3; round++)
        for (int i = 0; i < 2; i++) {
            runBlock(t, &b, rates[i], 2, 4096, round == 0, 0, k[i]);
            k[i] += 4096;
        }
    for (int i = 0; i < 2; i++) {
        runBlock(t, &b, rates[i], 2, 4096, false, 0, k[i]);
        k[i] += 4096;
        check(isScaled(&b, 2, 4096, EQ6, 0), "both live slots took the new configuration");
    }
    navis_tap_formats_set_cents(t, 300);
    for (int round = 0; round < 3; round++)
        for (int i = 0; i < 2; i++) {
            runBlock(t, &b, rates[i], 2, 4096, false, 0, k[i]);
            k[i] += 4096;
        }
    check(g_aus[0]->lastCents == 300 && g_aus[1]->lastCents == 300, "both live slots took the cents");
    // A later format is seeded with both.
    check(prepare(t, 22050, 2), "C");
    check(g_aus[2]->lastCents == 300, "the later slot's stage is built at the requested cents");
    runBlock(t, &b, 22050, 2, 1024, true, 0, k[2]);
    k[2] += 1024;
    runBlock(t, &b, 22050, 2, 1024, false, 0, k[2]);
    for (int c2 = 0; c2 < 2; c2++)
        for (int i = 0; i < 1024; i++)
            near(b.out[c2][i], EQ6 * GAIN * sample(c2, k[2] + i - LAT), 2e-6, "the later slot has the configuration and is wet");
    navis_tap_formats_set_cents(t, 0);
    for (int i = 0; i < 3; i++) navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 9. concurrency

static uint32_t xorshift(uint32_t *s) {
    *s ^= *s << 13;
    *s ^= *s >> 17;
    *s ^= *s << 5;
    return *s;
}

typedef struct {
    NavisTapFormats *t;
    _Atomic int rate;        // 0 = stopped
    _Atomic int inProcess;
    _Atomic int quit;
    _Atomic uint32_t generation;
    _Atomic int lastFedRate; // the rate of the last block of the current run, 0 before one
    uint64_t fed;            // render thread only until joined
    int frames;
} Render;

static void *renderMain(void *arg) {
    Render *r = arg;
    Block *b = malloc(sizeof *b);
    long k = 0;
    int previous = 0;
    while (!atomic_load(&r->quit)) {
        int rate = atomic_load(&r->rate);
        if (!rate) {
            previous = 0;
            sched_yield();
            continue;
        }
        atomic_store(&r->inProcess, 1);
        if (atomic_load(&r->rate) != rate) { // stopped before the block began
            atomic_store(&r->inProcess, 0);
            continue;
        }
        runBlock(r->t, b, rate, 2, r->frames, rate != previous, atomic_load_explicit(&r->generation, memory_order_relaxed), k);
        previous = rate;
        k += r->frames;
        r->fed += (uint64_t)r->frames;
        atomic_store(&r->lastFedRate, rate);
        atomic_store(&r->inProcess, 0);
    }
    free(b);
    return NULL;
}

// After this returns the render thread is outside process and will stay there.
static void renderStop(Render *r) {
    atomic_store(&r->rate, 0);
    while (atomic_load(&r->inProcess)) sched_yield();
}

static void renderStart(Render *r, int rate) {
    atomic_store(&r->lastFedRate, 0);
    atomic_store(&r->rate, rate);
}

static int formatRate(int i) { return (int)lround(8000.0 * pow(1.1, i % 20)); }

static bool held(const NavisTapFormatsState *s, int rate) { return infoFor(s, rate, 2) != NULL; }

static void chaos(NavisTapFormats *t, Render *r, uint32_t *rng) {
    int n = 1 + (int)(xorshift(rng) % 4);
    for (int i = 0; i < n; i++) {
        switch (xorshift(rng) % 6) {
        case 0: {
            NavisEqConfig c = config(xorshift(rng) & 1 ? -6 : -12);
            navis_tap_formats_configure(t, &c);
            break;
        }
        case 1: {
            static const int32_t cents[] = {0, 300, -500};
            navis_tap_formats_set_cents(t, cents[xorshift(rng) % 3]);
            break;
        }
        case 2: {
            NavisTapFormatsState s = state(t);
            check(s.slotCount <= NAVIS_TAP_MAX_FORMATS && s.livePipelines >= 0 && s.livePipelines <= 3, "sane state");
            if (s.hasStream) check(s.stream.sampleRate > 0, "the reporting slot has a rate");
            break;
        }
        case 3:
            atomic_fetch_add(&r->generation, 1);
            break;
        default:
            for (uint32_t y = xorshift(rng) % 8; y > 0; y--) sched_yield();
        }
    }
}

// At rest (render stopped): the slot of the last block must be the block's own rate.
static void checkLastSlot(NavisTapFormats *t, Render *r) {
    int rate = atomic_load(&r->lastFedRate);
    if (!rate) return;
    NavisTapFormatsState s = state(t);
    check(s.hasStream && s.stream.sampleRate == rate, "the last block ran at the slot of its own rate");
}

static void testConcurrentPipelines(void) {
    NavisTapFormats *t = newSet(-12, 0);
    Render r = {.t = t, .frames = 256};
    pthread_t thread;
    check(pthread_create(&thread, NULL, renderMain, &r) == 0, "render thread");
    uint32_t rng = 0x9e3779b9u;
    for (int iteration = 0; iteration < 300; iteration++) {
        // Near the cap the next formats could not be made under a live pipeline: start
        // over at live == 0, as the cap rule does.
        NavisTapFormatsState s = state(t);
        if (s.slotCount >= 13) {
            for (int i = 0; s.slotCount < NAVIS_TAP_MAX_FORMATS; i++) {
                int fill = formatRate(i);
                if (held(&s, fill)) continue;
                check(prepare(t, fill, 2) && navis_tap_formats_unprepare(t), "fill to the cap");
                s = state(t);
            }
            for (int i = 0; i < 20; i++) {
                if (held(&s, formatRate(i))) continue;
                check(prepare(t, formatRate(i), 2) && navis_tap_formats_unprepare(t), "free-all at the cap, nothing live");
                break;
            }
            check(state(t).slotCount == 1, "the cap started over");
        }
        int a = formatRate(3 * iteration), b = formatRate(3 * iteration + 1), c = formatRate(3 * iteration + 2);
        check(prepare(t, a, 2), "A");
        renderStart(&r, a);
        chaos(t, &r, &rng);
        check(prepare(t, b, 2), "B prepared while A plays");
        chaos(t, &r, &rng);
        renderStop(&r);
        checkLastSlot(t, &r);
        renderStart(&r, b); // B's first block comes before A's unprepare
        check(navis_tap_formats_unprepare(t), "A ended");
        chaos(t, &r, &rng);
        check(prepare(t, c, 2), "C prepared while B plays");
        chaos(t, &r, &rng);
        renderStop(&r);
        checkLastSlot(t, &r);
        renderStart(&r, c);
        check(navis_tap_formats_unprepare(t), "B ended");
        chaos(t, &r, &rng);
        renderStop(&r);
        checkLastSlot(t, &r);
        check(navis_tap_formats_unprepare(t), "C ended");
    }
    atomic_store(&r.quit, 1);
    pthread_join(thread, NULL);
    NavisTapFormatsState s = state(t);
    check(s.livePipelines == 0 && s.prepareCalls >= 900, "balanced");
    check(s.unmatchedFrames == 0 && s.overlapBlocks == 0, "no block missed its slot or overlapped");
    check(atomic_load(&g_wrongRate) == 0, "no block reached a pitch stage of another rate");
    check(s.processedFrames == r.fed, "every audio block was processed by exactly one slot");
    check(r.fed > 0, "the render thread ran");
    freeSet(t);
}

typedef struct {
    NavisTapFormats *t;
    int rate, blocks, frames;
    uint32_t seed;
} Hammer;

static void *hammerMain(void *arg) {
    Hammer *h = arg;
    Block *b = malloc(sizeof *b);
    for (int i = 0; i < h->blocks; i++) {
        runBlock(h->t, b, h->rate, 2, h->frames, i == 0, 0, (long)i * h->frames);
        if (xorshift(&h->seed) % 8 == 0) sched_yield();
    }
    free(b);
    return NULL;
}

// Two pipelines of one format (monoFloat -> mono16 style) overlapping: the busy flag keeps them apart.
static void testTwoRenderThreadsOnOneSlot(void) {
    NavisTapFormats *t = newSet(-12, 300);
    check(prepare(t, 44100, 2) && prepare(t, 44100, 2), "two pipelines, one format");
    Hammer h[2] = {{t, 44100, 3000, 128, 1}, {t, 44100, 3000, 128, 2}};
    pthread_t threads[2];
    for (int i = 0; i < 2; i++) check(pthread_create(&threads[i], NULL, hammerMain, &h[i]) == 0, "thread");
    uint32_t rng = 7;
    for (int i = 0; i < 400; i++) {
        NavisTapFormatsState s = state(t);
        check(s.slotCount == 1, "one slot");
        if (xorshift(&rng) & 1) navis_tap_formats_set_cents(t, i & 1 ? 0 : 300);
        sched_yield();
    }
    for (int i = 0; i < 2; i++) pthread_join(threads[i], NULL);
    NavisTapFormatsState s = state(t);
    check(s.processedFrames + s.overlapBlocks * 128 == 2 * 3000 * 128, "every block was processed or counted as overlap");
    check(s.unmatchedFrames == 0, "none unmatched");
    navis_tap_formats_unprepare(t);
    navis_tap_formats_unprepare(t);
    freeSet(t);
}


// MARK: 10. a block without a rate

static void testBlocksWithoutARate(void) {
    static Block b;
    NavisTapFormats *t = newSet(-12, 0);
    check(prepare(t, 48000, 2) && prepare(t, 96000, 2), "48000 and 96000");
    long k = 0;
    for (int i = 0; i < 2; i++, k += 1024) {
        runBlock(t, &b, 48000, 2, 1024, i == 0, 0, k);
        runBlock(t, &b, 96000, 2, 1024, i == 0, 0, k);
    }
    check(navis_tap_formats_unprepare(t) && navis_tap_formats_unprepare(t), "both ended");
    check(prepare(t, 48000, 2), "a new pipeline of 48000, the latest prepare");
    // Its first block has an invalid range, and StartOfStream may come with it.
    runBlockAt(t, &b, 48000, 48000, 2, 1024, true, 0, k, 0);
    check(isScaled(&b, 2, 1024, EQ12, 0), "it runs in the latest prepared slot");
    runBlock(t, &b, 48000, 2, 1024, false, 0, k);
    NavisTapFormatsState s = state(t);
    check(infoFor(&s, 48000, 2)->resetCount == 1, "and its StartOfStream applies to that slot");
    check(infoFor(&s, 96000, 2)->resetCount == 0 && s.unmatchedFrames == 0, "not to the other, and nothing is unmatched");
    // The channel count has to match, else it passes dry and is counted.
    runBlockAt(t, &b, 48000, 48000, 3, 512, false, 0, 0, 0);
    check(isDry(&b, 3, 512) && state(t).unmatchedFrames == 512, "another channel count passes dry and counts");
    // After a prepare that gave no slot there is none to route to.
    check(!navis_tap_formats_prepare(t, 44100, 2, 4096, false), "an unsupported format");
    runBlockAt(t, &b, 44100, 44100, 2, 256, false, 0, 0, 0);
    check(isDry(&b, 2, 256) && state(t).unmatchedFrames == 768, "it passes dry and counts");
    navis_tap_formats_unprepare(t);
    navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 11. a coarse clock admits several rates

static void testCoarseClockKeepsTheSongOnItsSlot(void) {
    static Block b;
    static const int rates[] = {22050, 24000, 44100, 48000, 88200, 96000};
    static const int32_t scales[] = {600, 1000};
    static const int sizes[] = {136, 512};
    NavisTapFormats *t = newSet(-12, 0);
    for (int i = 0; i < 6; i++) check(prepare(t, rates[i], 2), "prepared");
    for (int i = 0; i < 6; i++) {
        // The song starts on its own clock, then the clock turns coarse.
        runBlock(t, &b, rates[i], 2, 1024, true, 0, 0);
        for (int sc = 0; sc < 2; sc++)
            for (int sz = 0; sz < 2; sz++)
                for (int rep = 0; rep < 3; rep++) {
                    uint64_t before = state(t).formats[i].processedFrames;
                    runBlockAt(t, &b, rates[i], scales[sc], 2, sizes[sz], false, 0, 0, ticks(sizes[sz], rates[i], scales[sc]));
                    if (state(t).formats[i].processedFrames != before + (uint64_t)sizes[sz])
                        fail("a song stays on its own slot on a coarse clock", rates[i], scales[sc] * 10000 + sizes[sz]);
                }
    }
    check(state(t).unmatchedFrames == 0, "none unmatched");
    for (int i = 0; i < 6; i++) navis_tap_formats_unprepare(t);
    freeSet(t);
    // Nothing to prefer: the nearest of the admitted rates.
    NavisTapFormats *u = newSet(-12, 0);
    check(prepare(u, 44100, 2) && prepare(u, 48000, 2) && prepare(u, 96000, 2), "44100, 48000, 96000");
    runBlock(u, &b, 96000, 2, 1024, true, 0, 0); // lastSlot and latest prepare: 96000
    runBlockAt(u, &b, 48000, 1000, 2, 136, false, 0, 0, ticks(136, 48000, 1000)); // 3 ticks: 45333 Hz
    check(state(u).formats[0].processedFrames == 136, "with neither last nor prepared among them, the nearest wins");
    for (int i = 0; i < 3; i++) navis_tap_formats_unprepare(u);
    freeSet(u);
}

// MARK: 12. a block dropped on a busy slot keeps its start

static void testDroppedBlockKeepsItsStart(void) {
    static Block b;
    NavisTapFormats *t = newSet(-12, 700); // pitch on: the fake renderer is where the second call starts
    check(prepare(t, 44100, 2), "one format");
    long k = 0;
    for (int i = 0; i < 3; i++, k += 1024) runBlock(t, &b, 44100, 2, 1024, i == 0, 0, k);
    check(state(t).resetCount == 0, "no reset so far");
    g_reenter.t = t;
    g_reenter.armed = 1;
    runBlock(t, &b, 44100, 2, 1024, false, 0, k); // another call with StartOfStream arrives in the middle of it
    k += 1024;
    NavisTapFormatsState s = state(t);
    check(s.overlapBlocks == 1 && s.resetCount == 0, "it found the slot busy and was dropped");
    runBlock(t, &b, 44100, 2, 1024, false, 0, k);
    s = state(t);
    check(s.resetCount == 1 && s.pitchResetCount == 1, "the next block of the slot carries its StartOfStream");
    navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 13. a slot whose pitch could not be built is rebuilt

static void testPitchStageRebuild(void) {
    static Block b;
    NavisTapFormats *t = newSet(-12, 700);
    g_failCreate = true;
    check(prepare(t, 44100, 2), "the format still gets its equalizer");
    NavisTapFormatsState s = state(t);
    check(s.hasStream && !s.hasPitch && s.pitchReason, "without a pitch stage, with the reason");
    g_failCreate = false;
    check(navis_tap_formats_unprepare(t) && prepare(t, 44100, 2), "the next prepare of that format");
    check(atomic_load(&g_creates) == 1, "builds the unit again");
    s = state(t);
    check(s.hasPitch && s.pitchReason == NULL && s.slotCount == 1, "and the slot has its pitch stage");
    long k = 0;
    for (int i = 0; i < 2; i++, k += 1024) runBlock(t, &b, 44100, 2, 1024, i == 0, 0, k);
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < 1024; i++)
            near(b.out[c][i], EQ12 * GAIN * sample(c, k - 1024 + i - LAT), 2e-6, "the recovered stage pitches, seeded with the cents");
    navis_tap_formats_set_cents(t, 0);
    navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 14. reasons

static void testReasonsStayUntilAnAudioBlockIsProcessed(void) {
    static Block b;
    NavisTapFormats *t = newSet(-12, 0);
    check(!navis_tap_formats_prepare(t, 44100, 2, 4096, false), "an unsupported format first");
    NavisTapFormatsState s = state(t);
    check(!s.hasStream && s.formatReason && s.pitchReason, "nothing has played: the reason shows");
    navis_tap_formats_unprepare(t);
    freeSet(t);

    t = newSet(-12, 0);
    check(prepare(t, 48000, 2), "a 48000 song");
    runBlock(t, &b, 48000, 2, 1024, true, 0, 0);
    check(!navis_tap_formats_prepare(t, 44100, 2, 4096, false), "the next song's format is unsupported");
    s = state(t);
    check(s.hasStream && s.stream.sampleRate == 48000 && s.formatReason == NULL, "the song playing still shows its own state");
    navis_tap_formats_note_dry(t, 1024); // the unsupported song's block fails the layout checks
    s = state(t);
    check(s.formatReason && s.pitchReason, "a block that passes unchanged shows the reason, not the previous slot");
    check(prepare(t, 48000, 2), "a later prepare");
    check(state(t).formatReason != NULL, "does not clear it");
    runBlock(t, &b, 48000, 2, 1024, false, 0, 1024);
    s = state(t);
    check(s.formatReason == NULL && s.pitchReason == NULL, "a processed block does");
    navis_tap_formats_note_dry(t, 0);
    check(state(t).formatReason == NULL, "an empty block is not dry");
    navis_tap_formats_unprepare(t);
    navis_tap_formats_unprepare(t);
    navis_tap_formats_unprepare(t);
    freeSet(t);
}

// MARK: 15. the balance counters

static void testBalanceCounters(void) {
    NavisTapFormats *t = newSet(-12, 0);
    for (int i = 0; i < 3; i++) check(prepare(t, 44100, 2), "prepared");
    for (int i = 0; i < 4; i++) navis_tap_formats_unprepare(t);
    NavisTapFormatsState s = state(t);
    check(s.prepareCalls == 3 && s.unprepareCalls == 4 && s.clampedUnprepares == 1 && s.livePipelines == 0,
          "three prepares, four unprepares, one clamped, none live");
    freeSet(t);
}

typedef struct {
    const char *name;
    void (*run)(void);
    bool concurrency;
} Test;

// argv: "--concurrency" runs only the threaded tests (the ThreadSanitizer build);
// "--only NAME" runs one test by name.
int main(int argc, char **argv) {
    static const Test tests[] = {
        {"formatFollowsTheBlock", testFormatFollowsTheBlock, false},
        {"reuseKeepsTheSlot", testReuseKeepsTheSlot, false},
        {"freeAllOnlyAtTheCap", testFreeAllOnlyAtTheCap, false},
        {"staleLastSlot", testStaleLastSlot, false},
        {"extraUnprepareIsClamped", testExtraUnprepareIsClamped, false},
        {"matching", testMatching, false},
        {"interleavedStartAndFlush", testInterleavedStartAndFlush, false},
        {"fanOut", testFanOut, false},
        {"blocksWithoutARate", testBlocksWithoutARate, false},
        {"coarseClockKeepsTheSongOnItsSlot", testCoarseClockKeepsTheSongOnItsSlot, false},
        {"droppedBlockKeepsItsStart", testDroppedBlockKeepsItsStart, false},
        {"pitchStageRebuild", testPitchStageRebuild, false},
        {"reasonsStayUntilAnAudioBlockIsProcessed", testReasonsStayUntilAnAudioBlockIsProcessed, false},
        {"balanceCounters", testBalanceCounters, false},
        {"concurrentPipelines", testConcurrentPipelines, true},
        {"twoRenderThreadsOnOneSlot", testTwoRenderThreadsOnOneSlot, true},
    };
    bool concurrencyOnly = argc > 1 && strcmp(argv[1], "--concurrency") == 0;
    const char *only = argc > 2 && strcmp(argv[1], "--only") == 0 ? argv[2] : NULL;
    for (size_t i = 0; i < sizeof tests / sizeof *tests; i++) {
        if (only ? strcmp(only, tests[i].name) != 0 : concurrencyOnly && !tests[i].concurrency) continue;
        tests[i].run();
        if (only) printf("ok %s\n", tests[i].name);
    }
    if (!only) {
        puts(concurrencyOnly
                 ? "Navis Darwin tap formats (concurrency): pipelines, free-all and overlap passed."
                 : "Navis Darwin tap formats: format follows the block, reuse, cap, matching, resets, fan-out and concurrency passed.");
    }
    return 0;
}
