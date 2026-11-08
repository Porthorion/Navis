// Host-side fixtures for NavisPitchStage.c (iOS independent pitch, I21) with a
// fake renderer: a delay of L frames times a marker gain, so every expectation
// is exact. Run by tool/equalizer_native_test.sh under ASan/UBSan.
#include "../just_audio/Sources/just_audio/NavisPitchStage.h"
#include "../just_audio/Sources/just_audio/NavisEqualizerDsp.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NAVIS_PI 3.14159265358979323846
#define RATE 48000
#define LATENCY 4096
#define MAX_FRAMES 8208
#define FADE 960 /* 20 ms at 48 kHz */
#define GAIN 0.5f
#define TOTAL 120000

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

// MARK: fake renderer

typedef struct {
    int channels, latency, pos;
    float line[2][LATENCY];
    int renders, resets, centsCalls;
    float lastCents;
    int failRenders; // fail this many renders
} Fake;

static int fakeRender(void *user, const float *const *in, float *const *out, int channels, int frames) {
    Fake *f = user;
    f->renders++;
    if (f->failRenders > 0) {
        f->failRenders--;
        return -1;
    }
    for (int i = 0; i < frames; i++) {
        for (int c = 0; c < channels; c++) {
            out[c][i] = GAIN * f->line[c][(f->pos + i) % LATENCY];
            f->line[c][(f->pos + i) % LATENCY] = in[c][i];
        }
    }
    f->pos = (f->pos + frames) % LATENCY;
    return 0;
}

static void fakeReset(void *user) {
    Fake *f = user;
    f->resets++;
    memset(f->line, 0, sizeof f->line);
    f->pos = 0;
}

static void fakeCents(void *user, float cents) {
    Fake *f = user;
    f->centsCalls++;
    f->lastCents = cents;
}

static NavisPitchStage *newStage(Fake *f, float cents) {
    memset(f, 0, sizeof *f);
    f->channels = 2;
    f->latency = LATENCY;
    NavisPitchRenderer r = {f, fakeRender, fakeReset, fakeCents, LATENCY};
    NavisPitchStage *s = navis_pitch_stage_new(&r, 2, MAX_FRAMES, RATE, cents);
    check(s != NULL, "stage created");
    return s;
}

// Deterministic non-periodic input, peak 0.9.
static float sample(int channel, long k) {
    return (float)(0.9 * sin(0.013 * (double)k * (1.0 + 1e-6 * (double)k) + channel));
}

static float inputBuf[2][TOTAL], outputBuf[2][TOTAL];

// Feeds frames [from, to) in blocks of `block` frames; `resetAt` (or -1) is the
// first frame of the block that carries a reset.
static void run(NavisPitchStage *s, long from, long to, int block, long resetAt) {
    for (long k = from; k < to;) {
        int n = (int)((to - k) < block ? (to - k) : block);
        float *ch[2] = {outputBuf[0] + k, outputBuf[1] + k};
        for (int c = 0; c < 2; c++)
            for (int i = 0; i < n; i++) ch[c][i] = inputBuf[c][k + i] = sample(c, k + i);
        if (k == resetAt) navis_pitch_stage_note_reset(s);
        navis_pitch_stage_process(s, ch, 2, n);
        k += n;
    }
}

static NavisPitchState state(NavisPitchStage *s) {
    NavisPitchState st;
    navis_pitch_stage_state(s, &st);
    return st;
}

// MARK: tests

static void testBypassIsBitExact(void) {
    Fake f;
    NavisPitchStage *s = newStage(&f, 0);
    static const int sizes[] = {1, 7, 512, 4096, 8208, 1000};
    long k = 0;
    for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++) {
        run(s, k, k + sizes[i], sizes[i], -1);
        k += sizes[i];
    }
    for (long i = 0; i < k; i++)
        for (int c = 0; c < 2; c++) check(memcmp(&outputBuf[c][i], &inputBuf[c][i], 4) == 0, "pitch 0 is bit-exact");
    check(f.renders == 0, "the renderer is not touched at pitch 0");
    check(!state(s).active, "inactive at pitch 0");
    navis_pitch_stage_free(s);
}

static void testWetFromFirstFrameAndFrameParity(void) {
    static const int sizes[] = {1, 512, 4096, 8208, 333, 8208, 1, 4097};
    for (int pass = 0; pass < 2; pass++) {
        Fake f;
        NavisPitchStage *s = newStage(&f, 700); // a fresh stage at non-zero cents is wet at once
        long k = 0;
        for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++) {
            // pass 1 repeats the sizes as 12000-frame chunks of one oversize block
            int size = pass == 0 ? sizes[i] : 12000;
            run(s, k, k + size, size, -1);
            k += size;
        }
        for (long i = 0; i < k; i++)
            for (int c = 0; c < 2; c++) {
                float expected = i < LATENCY ? 0 : GAIN * inputBuf[c][i - LATENCY];
                near(outputBuf[c][i], expected, 0, "wet from the first frame, output k = input k - L");
            }
        check(f.lastCents == 700 && state(s).active && state(s).latencyFrames == LATENCY, "fresh stage reports its cents");
        check(f.resets == 0, "a fresh stage does not reset its renderer");
        navis_pitch_stage_free(s);
    }
}

static void testUserEnableDryThenRamp(void) {
    Fake f;
    NavisPitchStage *s = newStage(&f, 0);
    const long k0 = 5120, block = 512;
    run(s, 0, k0, block, -1);
    navis_pitch_stage_request(s, 700);
    run(s, k0, k0 + 4096 + FADE + 4096, block, -1);
    check(f.resets == 1 && f.lastCents == 700, "0 -> non-0 resets the renderer and sets the cents");
    for (long k = k0; k < k0 + LATENCY; k++)
        for (int c = 0; c < 2; c++) near(outputBuf[c][k], inputBuf[c][k], 0, "dry until L frames were fed");
    int rampSeen = 0;
    for (long k = k0 + LATENCY; k < k0 + LATENCY + FADE; k++)
        for (int c = 0; c < 2; c++) {
            float dry = inputBuf[c][k], wet = GAIN * inputBuf[c][k - LATENCY];
            float lo = fminf(dry, wet) - 1e-6f, hi = fmaxf(dry, wet) + 1e-6f;
            check(isfinite(outputBuf[c][k]) && outputBuf[c][k] >= lo && outputBuf[c][k] <= hi, "ramp stays between dry and wet");
            check(fabsf(outputBuf[c][k]) <= 0.9f + 1e-6f, "no sample above the input peak");
            if (outputBuf[c][k] != dry && outputBuf[c][k] != wet) rampSeen++;
        }
    check(rampSeen > FADE, "the splice is a ramp");
    for (long k = k0 + LATENCY + FADE; k < k0 + LATENCY + FADE + 4096; k++)
        for (int c = 0; c < 2; c++) near(outputBuf[c][k], GAIN * inputBuf[c][k - LATENCY], 0, "wet after the ramp");
    navis_pitch_stage_free(s);
}

static void testDisableRampThenBypass(void) {
    Fake f;
    NavisPitchStage *s = newStage(&f, 700);
    const long k1 = 20 * 512;
    run(s, 0, k1, 512, -1);
    navis_pitch_stage_request(s, 0);
    run(s, k1, k1 + FADE + 3000, 512, -1);
    for (long k = k1; k < k1 + FADE; k++) {
        float dry = inputBuf[0][k], wet = GAIN * inputBuf[0][k - LATENCY];
        float lo = fminf(dry, wet) - 1e-6f, hi = fmaxf(dry, wet) + 1e-6f;
        check(outputBuf[0][k] >= lo && outputBuf[0][k] <= hi && fabsf(outputBuf[0][k]) <= 0.9f + 1e-6f, "wet -> dry ramp stays between the two");
    }
    int renders = f.renders;
    for (long k = k1 + FADE + 512; k < k1 + FADE + 3000; k++) check(memcmp(&outputBuf[0][k], &inputBuf[0][k], 4) == 0, "bit-exact after the ramp");
    check(!state(s).active, "inactive after the ramp");
    run(s, k1 + FADE + 3000, k1 + FADE + 3000 + 512, 512, -1);
    check(f.renders == renders, "bypass does not feed the renderer");
    // And back on: dry, then the ramp (a user change never plays wet from nothing).
    navis_pitch_stage_request(s, -500);
    long k2 = k1 + FADE + 3512;
    run(s, k2, k2 + 4096 + FADE + 1024, 512, -1);
    check(f.resets == 1, "re-enabling resets the renderer once");
    for (long k = k2; k < k2 + LATENCY; k++) near(outputBuf[0][k], inputBuf[0][k], 0, "dry while the renderer fills");
    navis_pitch_stage_free(s);
}

static void testCentsChangeIsNotAReset(void) {
    Fake f;
    NavisPitchStage *s = newStage(&f, 700);
    run(s, 0, 8192, 512, -1);
    navis_pitch_stage_request(s, 1200);
    run(s, 8192, 12288, 512, -1);
    check(f.centsCalls == 2 && f.lastCents == 1200, "non-0 -> non-0 sets the cents");
    check(f.resets == 0, "and does not reset the renderer");
    for (long k = 8192 + 512; k < 12288; k++) near(outputBuf[0][k], GAIN * inputBuf[0][k - LATENCY], 0, "audio is continuous across the cents change");
    navis_pitch_stage_request(s, 99999);
    run(s, 12288, 12800, 512, -1);
    check(f.lastCents == 2400, "cents are clamped to the AU range");
    navis_pitch_stage_request(s, -99999);
    run(s, 12800, 13312, 512, -1);
    check(f.lastCents == -2400, "and below");
    navis_pitch_stage_free(s);
}

static void testResetRule(void) {
    Fake f;
    NavisPitchStage *s = newStage(&f, 700);
    run(s, 0, 20 * 512, 512, -1);
    check(state(s).resetCount == 1 && f.resets == 0, "the first audio block counts as the stage's reset");
    // No reset: a long run of blocks (natural item change, range re-base, pause/resume).
    run(s, 20 * 512, 100 * 512, 512, -1);
    check(state(s).resetCount == 1 && f.resets == 0, "blocks without a reset never reset");
    for (long k = 30 * 512; k < 100 * 512; k++) near(outputBuf[0][k], GAIN * inputBuf[0][k - LATENCY], 0, "audio plays on across blocks");
    // A reset drops the delay line: zeros for L frames, then the input shifted by L.
    long r = 100 * 512;
    navis_pitch_stage_note_reset(s);
    navis_pitch_stage_note_reset(s); // latched: two notes before a block are one reset
    run(s, r, r + 12000, 512, -1);
    check(state(s).resetCount == 2 && f.resets == 1, "one reset, counted once");
    for (long k = r; k < r + LATENCY; k++) near(outputBuf[0][k], 0, 0, "wet from the first frame after a reset: silence for L");
    for (long k = r + LATENCY; k < r + 12000; k++) near(outputBuf[0][k], GAIN * inputBuf[0][k - LATENCY], 0, "then the input at k - L");
    // A reset during the user's dry priming is wet from the first frame as well.
    Fake ft;
    NavisPitchStage *t = newStage(&ft, 0);
    run(t, 0, 2048, 512, -1);
    navis_pitch_stage_request(t, 300);
    run(t, 2048, 2048 + 1024, 512, -1); // priming (dry)
    navis_pitch_stage_note_reset(t);
    run(t, 3072, 3072 + 2 * LATENCY, 512, -1);
    for (long k = 3072; k < 3072 + LATENCY; k++) near(outputBuf[0][k], 0, 0, "reset during priming plays wet from nothing");
    for (long k = 3072 + LATENCY; k < 3072 + 2 * LATENCY; k++) near(outputBuf[0][k], GAIN * inputBuf[0][k - LATENCY], 0, "and then wet");
    // A reset at pitch 0 only counts.
    Fake fu;
    NavisPitchStage *u = newStage(&fu, 0);
    run(u, 0, 512, 512, -1);
    navis_pitch_stage_note_reset(u);
    run(u, 512, 1024, 512, -1);
    check(state(u).resetCount == 2 && fu.renders == 0, "a reset at pitch 0 is counted and touches nothing");
    for (long k = 0; k < 1024; k++) check(memcmp(&outputBuf[0][k], &inputBuf[0][k], 4) == 0, "still bit-exact");
    navis_pitch_stage_free(s);
    navis_pitch_stage_free(t);
    navis_pitch_stage_free(u);
}

static void testTail(void) {
    Fake f;
    NavisPitchStage *s = newStage(&f, 700);
    run(s, 0, 20000, 4096, -1);
    // The source ends; AVPlayer keeps calling with silent blocks (L frames of them
    // bring out the delayed input exactly).
    for (long k = 20000; k < 20000 + LATENCY; k++)
        for (int c = 0; c < 2; c++) inputBuf[c][k] = 0;
    for (long k = 20000; k < 20000 + LATENCY; k += 1024) {
        float *ch[2] = {outputBuf[0] + k, outputBuf[1] + k};
        memset(ch[0], 0, 1024 * 4);
        memset(ch[1], 0, 1024 * 4);
        navis_pitch_stage_process(s, ch, 2, 1024);
    }
    for (long k = 20000; k < 20000 + LATENCY; k++) near(outputBuf[0][k], GAIN * inputBuf[0][k - LATENCY], 0, "the tail comes out after L silent frames");
    navis_pitch_stage_free(s);
}

static void testRenderFailureAndLayout(void) {
    Fake f;
    NavisPitchStage *s = newStage(&f, 700);
    f.failRenders = 1;
    run(s, 0, 512, 512, -1);
    check(state(s).renderErrors == 1, "a failed render is counted");
    for (long k = 0; k < 512; k++) check(isfinite(outputBuf[0][k]), "and the output stays finite");
    // A channel count that differs from the stage's passes through untouched.
    float mono[64];
    for (int i = 0; i < 64; i++) mono[i] = (float)i;
    float *ch[1] = {mono};
    int renders = f.renders;
    navis_pitch_stage_process(s, ch, 1, 64);
    check(f.renders == renders && mono[63] == 63.0f, "a different channel layout passes through");
    navis_pitch_stage_free(s);
}

static void testHzMeters(void) {
    Fake f;
    for (int cents = 0; cents <= 700; cents += 700) {
        NavisPitchStage *s = newStage(&f, (float)cents);
        for (long k = 0; k < 3 * RATE; k += 1024) {
            float buf[2][1024];
            float *ch[2] = {buf[0], buf[1]};
            for (int i = 0; i < 1024; i++) buf[0][i] = buf[1][i] = (float)(0.5 * sin(2 * NAVIS_PI * 440.0 * (double)(k + i) / RATE));
            navis_pitch_stage_process(s, ch, 2, 1024);
        }
        NavisPitchState st = state(s);
        near(st.inputHz, 440, 4.4, "input Hz, with or without the pitch stage");
        near(st.outputHz, 440, 4.4, "output Hz of the fake (a pure delay keeps the frequency)");
        navis_pitch_stage_free(s);
    }
}

// What tapProcess does: the value navis_eq_stream_begin_block returns is what
// the pitch stage is told. The EQ stream and the pitch stage see the same blocks.
static void testStageFollowsEqualizerResetDecision(void) {
    NavisEqConfig cfg;
    memset(&cfg, 0, sizeof cfg);
    NavisEqStream *eq = navis_eq_stream_new(&cfg, RATE, 2);
    check(eq != NULL, "eq stream");
    Fake f;
    NavisPitchStage *s = newStage(&f, 700);
    struct { bool start; uint32_t generation; int frames; int expectResets; } steps[] = {
        {true, 0, 0, 0},    // StartOfStream on an empty block: latched
        {false, 0, 512, 1}, // first audio: the stage counts its own start
        {false, 0, 512, 1}, // steady
        {false, 0, 0, 1},   // pause: empty blocks
        {false, 0, 512, 1}, // resume: no reset
        {false, 1, 0, 1},   // seek: flush noted, empty block
        {false, 1, 512, 2}, // the first audio after the flush resets
        {false, 1, 512, 2},
    };
    long k = 0;
    for (size_t i = 0; i < sizeof steps / sizeof *steps; i++) {
        bool reset = navis_eq_stream_begin_block(eq, steps[i].start, steps[i].generation, steps[i].frames);
        if (reset) navis_pitch_stage_note_reset(s);
        if (steps[i].frames > 0) {
            run(s, k, k + steps[i].frames, steps[i].frames, -1);
            k += steps[i].frames;
        }
        if (state(s).resetCount != (uint64_t)steps[i].expectResets) fail("stage resets follow begin_block", steps[i].expectResets, (double)state(s).resetCount);
    }
    navis_pitch_stage_free(s);
    navis_eq_stream_free(eq);
}

int main(void) {
    testBypassIsBitExact();
    testWetFromFirstFrameAndFrameParity();
    testUserEnableDryThenRamp();
    testDisableRampThenBypass();
    testCentsChangeIsNotAReset();
    testResetRule();
    testTail();
    testRenderFailureAndLayout();
    testHzMeters();
    testStageFollowsEqualizerResetDecision();
    puts("Navis Darwin pitch stage: bypass, wet-from-reset, ramps, frame parity, reset rule, tail and meters passed.");
    return 0;
}
