// Darwin-only fixtures for NavisPitchAU.c: the real AUNewTimePitch behind the
// NavisPitchRenderer. Run by tool/equalizer_native_test.sh on macOS and in the
// macOS CI job (the script prints SKIPPED elsewhere). Build with
// `cc -std=c11 -DNAVIS_PITCH_AU_HOST_TEST ... -framework AudioToolbox`.
#include "../just_audio/Sources/just_audio/NavisPitchAU.h"

#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NAVIS_PI 3.14159265358979323846

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define NAVIS_ALLOC_HOOKS 1
#include <sanitizer/allocator_interface.h>
#endif
#endif

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

// Renders `total` frames of `hz` (silence after `inputFrames`) in blocks of `block`
// frames into out[0] (left); returns the number of frames the renderer produced.
// Every render must leave the guard word after its frames untouched.
static void renderSine(NavisPitchAU *au, NavisPitchRenderer r, double rate, double hz, long inputFrames,
                       long total, int block, float *out, long firstFrame) {
    float *inBuf[2], *outBuf[2];
    for (int c = 0; c < 2; c++) {
        inBuf[c] = calloc((size_t)block + 1, sizeof(float));
        outBuf[c] = calloc((size_t)block + 1, sizeof(float));
    }
    for (long k = 0; k < total; k += block) {
        int n = (int)((total - k) < block ? (total - k) : block);
        for (int i = 0; i < n; i++) {
            float v = k + i < inputFrames ? (float)(0.5 * sin(2 * NAVIS_PI * hz * (double)(firstFrame + k + i) / rate)) : 0.f;
            inBuf[0][i] = inBuf[1][i] = v;
        }
        for (int c = 0; c < 2; c++) outBuf[c][n] = 12345.f;
        const float *in[2] = {inBuf[0], inBuf[1]};
        float *o[2] = {outBuf[0], outBuf[1]};
        check(r.render(r.user, in, o, 2, n) == 0, "render succeeds");
        check(outBuf[0][n] == 12345.f && outBuf[1][n] == 12345.f, "frame parity: the AU wrote only the frames it was asked for");
        memcpy(out + k, outBuf[0], (size_t)n * sizeof(float));
    }
    for (int c = 0; c < 2; c++) {
        free(inBuf[c]);
        free(outBuf[c]);
    }
    (void)au;
}

static double crossingsHz(const float *x, long from, long to, double rate) {
    long crossings = 0;
    for (long i = from + 1; i < to; i++)
        if (x[i - 1] <= 0 && x[i] > 0) crossings++;
    return (double)crossings * rate / (double)(to - from);
}

static void testRatios(void) {
    static const double rates[] = {44100, 48000, 96000};
    static const float cents[] = {1200, 700, -1200, 2400, -2400};
    for (size_t ri = 0; ri < 3; ri++) {
        double rate = rates[ri];
        int maxFrames = rate > 50000 ? 8192 : 4096;
        long total = (long)(rate * 4);
        float *out = calloc((size_t)total, sizeof(float));
        for (size_t ci = 0; ci < 5; ci++) {
            NavisPitchAU *au = navis_pitch_au_new(rate, 2, maxFrames);
            check(au != NULL, "AUNewTimePitch available");
            NavisPitchRenderer r = navis_pitch_au_renderer(au);
            r.set_cents(r.user, cents[ci]);
            renderSine(au, r, rate, 440, total, total, maxFrames, out, 0);
            double ratio = crossingsHz(out, total / 2, total, rate) / 440.0;
            near(ratio, pow(2, cents[ci] / 1200.0), pow(2, cents[ci] / 1200.0) * 0.01, "frequency ratio within 1%");
            check(navis_pitch_au_pull_mismatches(au) == 0, "every input pull matched its block");
            navis_pitch_au_free(au);
        }
        free(out);
    }
}

static void testLatencyOnsetTailAndReset(void) {
    static const double rates[] = {44100, 48000, 96000};
    for (size_t ri = 0; ri < 3; ri++) {
        double rate = rates[ri];
        int maxFrames = rate > 50000 ? 8192 : 4096;
        NavisPitchAU *au = navis_pitch_au_new(rate, 2, maxFrames);
        check(au != NULL, "AUNewTimePitch available");
        NavisPitchRenderer r = navis_pitch_au_renderer(au);
        r.set_cents(r.user, 700);
        near(r.latencyFrames, maxFrames, 64, "reported latency is one block (4096 frames, 8192 at 96 kHz)");
        long total = r.latencyFrames * 6, inputFrames = r.latencyFrames * 4;
        float *out = calloc((size_t)total, sizeof(float));
        renderSine(au, r, rate, 440, inputFrames, total, 1024, out, 0);
        long onset = -1;
        for (long i = 0; i < total; i++)
            if (fabsf(out[i]) > 0.05f) {
                onset = i;
                break;
            }
        check(onset >= 0, "audio comes out");
        near((double)onset, (double)r.latencyFrames, 64, "measured onset equals the reported latency");
        // The tail: the input ended at inputFrames; the last L frames of it are still inside.
        double tail = 0;
        for (long i = inputFrames; i < inputFrames + r.latencyFrames; i++) tail += (double)out[i] * out[i];
        check(sqrt(tail / r.latencyFrames) > 0.05, "the tail comes out of the L frames after the input ended");
        // A reset drops it: the next L frames are silent.
        r.reset(r.user);
        renderSine(au, r, rate, 440, total, r.latencyFrames, 1024, out, 0);
        double rms = 0;
        for (long i = 0; i < r.latencyFrames - 64; i++) rms += (double)out[i] * out[i];
        check(sqrt(rms / (r.latencyFrames - 64)) < 0.01, "silence for L frames after a reset");
        free(out);
        navis_pitch_au_free(au);
    }
}

static void testTimestampMonotonicAcrossReset(void) {
    NavisPitchAU *au = navis_pitch_au_new(48000, 2, 4096);
    check(au != NULL, "AUNewTimePitch available");
    NavisPitchRenderer r = navis_pitch_au_renderer(au);
    r.set_cents(r.user, 1200);
    float *out = calloc(48000, sizeof(float));
    for (int round = 0; round < 3; round++) { // seeks restart the audio, never the AU clock
        r.reset(r.user);
        renderSine(au, r, 48000, 440, 48000, 48000, 2048, out, 0);
    }
    near(crossingsHz(out, 24000, 48000, 48000) / 880.0, 1.0, 0.01, "frequency is right after repeated resets");
    free(out);
    navis_pitch_au_free(au);
}

#ifdef NAVIS_ALLOC_HOOKS
static _Atomic bool g_counting;
static _Atomic long g_allocations;
static void countMalloc(const volatile void *p, size_t n) {
    (void)p; (void)n;
    if (atomic_load(&g_counting)) atomic_fetch_add(&g_allocations, 1);
}
static void countFree(const volatile void *p) {
    (void)p;
    if (atomic_load(&g_counting)) atomic_fetch_add(&g_allocations, 1);
}
#endif

// #479e: the stage calls render, reset and set_cents on the render thread. None of
// them may allocate or free (a seek resets with pitch on). Timing is logged by the
// sweep probe, not asserted here: it is too noisy for CI.
static void testRenderThreadCallsDoNotAllocate(void) {
#ifdef NAVIS_ALLOC_HOOKS
    __sanitizer_install_malloc_and_free_hooks(countMalloc, countFree);
    atomic_store(&g_counting, true);
    void *volatile probe = malloc(16); // volatile: the compiler may drop a bare malloc/free pair
    free(probe);
    atomic_store(&g_counting, false);
    check(atomic_load(&g_allocations) == 2, "the allocation hooks see a malloc and a free");
    enum { CH = 2, FRAMES = 4096 };
    NavisPitchAU *au = navis_pitch_au_new(44100, CH, FRAMES);
    check(au != NULL, "AUNewTimePitch available");
    NavisPitchRenderer r = navis_pitch_au_renderer(au);
    float *buffer = calloc(4 * FRAMES, sizeof(float));
    const float *in[CH] = {buffer, buffer + FRAMES};
    float *out[CH] = {buffer + 2 * FRAMES, buffer + 3 * FRAMES};
    for (int i = 0; i < FRAMES; i++) buffer[i] = buffer[FRAMES + i] = (float)(0.5 * sin(0.1 * i));
    r.set_cents(r.user, 1200);
    for (int i = 0; i < 8; i++) check(r.render(r.user, in, out, CH, FRAMES) == 0, "render warms up");
    atomic_store(&g_allocations, 0);
    atomic_store(&g_counting, true);
    for (int i = 0; i < 64; i++) { // a seek with pitch on, a pitch change, then audio
        r.reset(r.user);
        r.set_cents(r.user, i & 1 ? 700.f : 1200.f);
        r.render(r.user, in, out, CH, FRAMES);
    }
    atomic_store(&g_counting, false);
    __sanitizer_install_malloc_and_free_hooks(NULL, NULL);
    long allocations = atomic_load(&g_allocations);
    if (allocations != 0) fail("allocations and frees in render, reset and set_cents", 0, (double)allocations);
    free(buffer);
    navis_pitch_au_free(au);
#else
    puts("SKIPPED: the pitch AU allocation check needs AddressSanitizer's allocator hooks.");
#endif
}

int main(void) {
    testRatios();
    testLatencyOnsetTailAndReset();
    testTimestampMonotonicAcrossReset();
    testRenderThreadCallsDoNotAllocate();
    puts("Navis Darwin pitch AU: frequency ratios at 44.1/48/96 kHz, latency, onset, tail, reset, frame parity and no allocation on the render thread passed.");
    return 0;
}
