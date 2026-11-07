// Host-side fixtures for NavisEqualizerDsp.c, mirroring android EqualizerDspTest.java
// plus the stream (swap, crossfade, levels, lifetime) behaviour. Run by
// tool/equalizer_native_test.sh; build with `cc -std=c11 -pthread ... -lm`.
#include "../just_audio/Sources/just_audio/NavisEqualizerDsp.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NAVIS_PI 3.14159265358979323846

static void fail(const char *context, double expected, double actual) {
    fprintf(stderr, "FAIL %s: expected %g, received %g\n", context, expected, actual);
    exit(1);
}

static void near(double actual, double expected, double tolerance, const char *context) {
    if (!isfinite(actual) || fabs(actual - expected) > tolerance) fail(context, expected, actual);
}

static void check(bool ok, const char *context) {
    if (!ok) fail(context, 1, 0);
}

static NavisEqFilter filter(int type, double frequency, double gain, double q) {
    NavisEqFilter f = {type, frequency, gain, q, true};
    return f;
}

static NavisEqConfig config(bool enabled, bool autoHeadroom, double preamp, const NavisEqFilter *filters, int count) {
    NavisEqConfig c;
    memset(&c, 0, sizeof c);
    c.enabled = enabled;
    c.autoHeadroom = autoHeadroom;
    c.preamp = preamp;
    c.filterCount = count;
    for (int i = 0; i < count; i++) c.filters[i] = filters[i];
    return c;
}

static NavisEqBiquad coeffs(NavisEqFilter f, double sampleRate) {
    NavisEqBiquad b;
    check(navis_eq_coefficients(&f, sampleRate, &b), "coefficients");
    return b;
}

static double measuredGain(NavisEqBank *bank, double frequency) {
    double inputPower = 0, outputPower = 0;
    for (int i = 0; i < 96000; i++) {
        double input = 0.02 * sin(2 * NAVIS_PI * frequency * i / 48000);
        double output = navis_eq_bank_process(bank, input, 0);
        check(isfinite(output), "Nonfinite audio output");
        if (i >= 48000) {
            inputPower += input * input;
            outputPower += output * output;
        }
        near(navis_eq_bank_process(bank, 0, 1), 0, 0, "Stereo channel isolation");
    }
    return 10 * log10(outputPower / inputPower);
}

static void testDspMirror(void) {
    const double rates[] = {44100, 48000, 96000};
    const double qs[] = {0.1, 0.7, 1.41, 6, 20};
    for (int r = 0; r < 3; r++) {
        double sr = rates[r];
        for (int q = 0; q < 5; q++) {
            NavisEqBiquad peak = coeffs(filter(NAVIS_EQ_PEAKING, 1234.5, 9.3, qs[q]), sr);
            near(navis_eq_biquad_db_at(&peak, 1234.5, sr), 9.3, 0.00001, "Peaking center/Q");
        }
        NavisEqBiquad low = coeffs(filter(NAVIS_EQ_LOW_SHELF, 105, 6, 0.7), sr);
        near(navis_eq_biquad_db_at(&low, 105, sr), 3, 0.00001, "AutoEQ low shelf/Q");
        NavisEqBiquad high = coeffs(filter(NAVIS_EQ_HIGH_SHELF, 10000, -6, 0.7), sr);
        near(navis_eq_biquad_db_at(&high, 10000, sr), -3, 0.00001, "AutoEQ high shelf/Q");
        int passes[] = {NAVIS_EQ_LOW_PASS, NAVIS_EQ_HIGH_PASS};
        for (int p = 0; p < 2; p++) {
            NavisEqBiquad pass = coeffs(filter(passes[p], 1000, 0, sqrt(0.5)), sr);
            near(navis_eq_biquad_db_at(&pass, 1000, sr), -3.0102999566, 0.00001, "Butterworth cutoff");
        }
    }
    NavisEqFilter overlapping[] = {filter(NAVIS_EQ_PEAKING, 1000, 6, 1), filter(NAVIS_EQ_PEAKING, 1000, 6, 1)};
    NavisEqConfig protectedCfg = config(true, true, 0, overlapping, 2);
    NavisEqBank *protectedBank = navis_eq_bank_new(&protectedCfg, 48000, 2);
    near(protectedBank->headroom, -12.5, 0.001, "Combined boost headroom");
    near(measuredGain(protectedBank, 1000), -0.5, 0.01, "Measured PCM response with headroom");
    navis_eq_bank_free(protectedBank);

    NavisEqConfig unrestrictedCfg = config(true, false, -3, overlapping, 2);
    NavisEqBank *unrestricted = navis_eq_bank_new(&unrestrictedCfg, 48000, 2);
    near(measuredGain(unrestricted, 1000), 9, 0.01, "Measured PCM preamp/curve");
    navis_eq_bank_free(unrestricted);

    NavisEqConfig bypassCfg = config(false, true, 24, overlapping, 2);
    NavisEqBank *bypass = navis_eq_bank_new(&bypassCfg, 48000, 2);
    near(measuredGain(bypass, 1000), 0, 0.000001, "Bypass is unity");
    navis_eq_bank_free(bypass);

    NavisEqFilter high16k[] = {filter(NAVIS_EQ_PEAKING, 16000, 6, 1)};
    NavisEqConfig lowRateCfg = config(true, true, 0, high16k, 1);
    NavisEqBank *lowRate = navis_eq_bank_new(&lowRateCfg, 22050, 2);
    check(!lowRate->enabled && lowRate->reason != NULL, "Low-rate profile was partially applied");
    near(navis_eq_bank_process(lowRate, 0.12345, 0), 0.12345, 0, "Unsupported complete-profile bypass");
    navis_eq_bank_free(lowRate);

    NavisEqFilter bad = filter(NAVIS_EQ_PEAKING, 1000, 25, 1);
    check(!navis_eq_filter_valid(&bad), "Invalid filter accepted");
    check(navis_eq_filter_type_from_name("highShelf") == NAVIS_EQ_HIGH_SHELF, "type name");
    check(navis_eq_filter_type_from_name("bogus") == -1, "unknown type name");
    NavisEqConfig tooQuiet = config(true, true, -61, NULL, 0);
    check(navis_eq_bank_new(&tooQuiet, 48000, 2) == NULL, "Out-of-range preamp accepted");
    check(navis_eq_bank_new(&protectedCfg, 48000, 9) == NULL, "Too many channels accepted");
}

#define FRAMES 1024

static float *planar[2];

static void fillSine(double frequency, long *position) {
    for (int i = 0; i < FRAMES; i++, (*position)++) {
        float v = (float)(0.1 * sin(2 * NAVIS_PI * frequency * *position / 48000));
        planar[0][i] = v;
        planar[1][i] = v;
    }
}

static void runBlocks(NavisEqStream *s, int blocks, long *position) {
    for (int i = 0; i < blocks; i++) {
        fillSine(1000, position);
        navis_eq_stream_process(s, planar, 2, FRAMES);
    }
}

static void testStream(void) {
    planar[0] = calloc(FRAMES, sizeof(float));
    planar[1] = calloc(FRAMES, sizeof(float));
    long position = 0;
    NavisEqStreamState st;

    // Flat filters, preamp -12 dB, no auto headroom: level change is -12 dB.
    NavisEqFilter flat[] = {filter(NAVIS_EQ_PEAKING, 1000, 0, 1), filter(NAVIS_EQ_LOW_SHELF, 100, 0, 0.7)};
    NavisEqConfig quiet = config(true, false, -12, flat, 2);
    NavisEqStream *s = navis_eq_stream_new(&quiet, 48000, 2);
    navis_eq_stream_state(s, &st);
    check(st.sampleRate == 48000 && !st.pending && st.enabled && !st.hasLevel, "initial state");
    check(st.processedFrames == 0, "no frames yet");
    runBlocks(s, 100, &position);
    navis_eq_stream_state(s, &st);
    check(st.processedFrames == 100 * FRAMES, "processedFrames counts frames");
    check(st.hasLevel, "level available");
    near(st.levelDeltaDb, -12, 0.05, "levelDeltaDb with preamp -12");

    // Switch to EQ off: pending until the audio thread swaps, then ~0 dB.
    NavisEqConfig off = config(false, false, -12, flat, 2);
    check(navis_eq_stream_request(s, &off), "request accepted");
    navis_eq_stream_state(s, &st);
    check(st.pending && st.enabled, "pending before the next block");
    runBlocks(s, 1, &position);
    navis_eq_stream_state(s, &st);
    check(!st.pending && !st.enabled, "swapped at the block boundary");
    runBlocks(s, 200, &position);
    navis_eq_stream_state(s, &st);
    near(st.levelDeltaDb, 0, 0.001, "levelDeltaDb with EQ off");

    // After a live edit the level reading follows it within a fraction of a second.
    check(navis_eq_stream_request(s, &quiet), "request quiet again");
    runBlocks(s, 12, &position); // 12288 frames: fade (960) plus a window
    navis_eq_stream_state(s, &st);
    near(st.levelDeltaDb, -12, 0.05, "levelDeltaDb follows a live edit back to -12");
    check(navis_eq_stream_request(s, &off), "request off again");
    runBlocks(s, 12, &position);
    navis_eq_stream_state(s, &st);
    near(st.levelDeltaDb, 0, 0.001, "levelDeltaDb follows a live edit to off");
    check(navis_eq_stream_request(s, &quiet), "request quiet third");
    runBlocks(s, 2, &position);
    navis_eq_stream_state(s, &st);
    near(st.levelDeltaDb, -12, 0.05, "levelDeltaDb after 2 blocks past the fade");

    // Crossfade: first output block after a swap moves smoothly (no jump
    // larger than the signal could produce), and ends at the new bank's gain.
    check(navis_eq_stream_request(s, &quiet), "request quiet");
    fillSine(1000, &position);
    float input[FRAMES];
    memcpy(input, planar[0], sizeof input);
    navis_eq_stream_process(s, planar, 2, FRAMES);
    near(planar[0][0], input[0], 1e-4, "fade starts at the old (unity) gain");
    int fadeFrames = 48000 / 50;
    for (int i = fadeFrames + 8; i < FRAMES; i++) {
        near(planar[0][i], input[i] * pow(10, -12.0 / 20), 2e-3, "fade ends at the new gain");
    }

    // Channel-count mismatch passes through untouched.
    float mono[8] = {0.5f, -0.5f, 0.25f, 0, 0, 0, 0, 0};
    float *monoPtr[1] = {mono};
    navis_eq_stream_process(s, monoPtr, 1, 8);
    near(mono[0], 0.5, 0, "mismatched channel count untouched");
    check(!navis_eq_stream_request(s, &(NavisEqConfig){.preamp = 99}), "invalid request rejected");

    // Many edits while no audio is processing stay bounded: a stream that is
    // not running holds applied + requested (+ at most one fading bank).
    for (int i = 0; i < 500; i++) {
        NavisEqConfig c = config(true, true, -(double)(i % 20), flat, 2);
        check(navis_eq_stream_request(s, &c), "edit while paused");
    }
    check(navis_eq_stream_bank_count(s) <= 3, "idle stream keeps a bounded number of banks");
    // Same while audio runs, with edits between blocks.
    for (int i = 0; i < 200; i++) {
        NavisEqConfig c = config(true, false, -(double)(i % 20), flat, 2);
        check(navis_eq_stream_request(s, &c), "edit while running");
        if (i % 3 == 0) runBlocks(s, 1, &position);
    }
    check(navis_eq_stream_bank_count(s) <= 4, "running stream keeps a bounded number of banks");
    navis_eq_stream_free(s);
    free(planar[0]);
    free(planar[1]);
}

// A discontinuity (seek, resumed playback) forgets the filter history.
static void testDiscontinuity(void) {
    NavisEqFilter fs[] = {filter(NAVIS_EQ_LOW_PASS, 200, 0, 0.7), filter(NAVIS_EQ_PEAKING, 500, 9, 2)};
    NavisEqConfig c = config(true, false, 0, fs, 2);
    NavisEqStream *s = navis_eq_stream_new(&c, 48000, 2);
    float left[256], right[256], freshL[256], freshR[256];
    float *ch[2] = {left, right}, *fresh[2] = {freshL, freshR};
    for (int i = 0; i < 256; i++) left[i] = right[i] = (float)sin(i * 0.3); // loud signal fills the history
    navis_eq_stream_process(s, ch, 2, 256);
    for (int i = 0; i < 256; i++) left[i] = right[i] = i == 0 ? 1.0f : 0.0f;
    navis_eq_stream_reset_history(s);
    navis_eq_stream_process(s, ch, 2, 256);
    NavisEqStream *reference = navis_eq_stream_new(&c, 48000, 2);
    for (int i = 0; i < 256; i++) freshL[i] = freshR[i] = i == 0 ? 1.0f : 0.0f;
    navis_eq_stream_process(reference, fresh, 2, 256);
    for (int i = 0; i < 256; i++) near(left[i], freshL[i], 1e-7, "impulse after reset matches a fresh stream");
    navis_eq_stream_free(s);
    navis_eq_stream_free(reference);
}

typedef struct {
    NavisEqStream *stream;
    atomic_bool stop;
    atomic_bool bad;
} AudioThread;

static void *audioMain(void *arg) {
    AudioThread *t = arg;
    float *chans[2] = {malloc(512 * sizeof(float)), malloc(512 * sizeof(float))};
    long pos = 0;
    while (!atomic_load(&t->stop)) {
        for (int i = 0; i < 512; i++, pos++) {
            chans[0][i] = chans[1][i] = (float)(0.2 * sin(2 * NAVIS_PI * 440 * pos / 44100));
        }
        navis_eq_stream_process(t->stream, chans, 2, 512);
        for (int i = 0; i < 512; i++) {
            if (!isfinite(chans[0][i]) || fabsf(chans[0][i]) > 8) atomic_store(&t->bad, true);
        }
    }
    free(chans[0]);
    free(chans[1]);
    return NULL;
}

// Run under ASan/TSan when available: edits race the audio thread, the sweep
// must never free a bank the audio thread can reach.
static void testThreadedEdits(void) {
    NavisEqFilter fs[] = {filter(NAVIS_EQ_PEAKING, 800, 6, 1), filter(NAVIS_EQ_HIGH_SHELF, 8000, -4, 0.7)};
    NavisEqConfig c0 = config(true, true, 0, fs, 2);
    AudioThread t;
    t.stream = navis_eq_stream_new(&c0, 44100, 2);
    atomic_init(&t.stop, false);
    atomic_init(&t.bad, false);
    pthread_t thread;
    pthread_create(&thread, NULL, audioMain, &t);
    for (int i = 0; i < 20000; i++) {
        NavisEqConfig c = config(i % 7 != 0, i % 2 == 0, -(double)(i % 24), fs, 2);
        c.filters[0].gain = (i % 25) - 12;
        navis_eq_stream_request(t.stream, &c);
        NavisEqStreamState st;
        navis_eq_stream_state(t.stream, &st);
        if (i % 50 == 0) {
            struct timespec ts = {0, 200000};
            nanosleep(&ts, NULL);
        }
    }
    atomic_store(&t.stop, true);
    pthread_join(thread, NULL);
    check(!atomic_load(&t.bad), "nonfinite or exploding output during edits");
    navis_eq_stream_request(t.stream, &c0);
    check(navis_eq_stream_bank_count(t.stream) <= 4, "threaded edits leave a bounded number of banks");
    navis_eq_stream_free(t.stream);
}

int main(void) {
    testDspMirror();
    testStream();
    testDiscontinuity();
    testThreadedEdits();
    puts("Navis Darwin equalizer DSP: response, headroom, bypass, limits, stream swap/crossfade, levels and threaded edits passed.");
    return 0;
}
