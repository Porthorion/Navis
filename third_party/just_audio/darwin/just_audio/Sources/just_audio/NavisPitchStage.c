#include "NavisPitchStage.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    MODE_BYPASS,   // pitch 0: the buffer is not touched
    MODE_PRIME,    // user switched on: dry out while the renderer fills
    MODE_RAMP_IN,  // dry -> wet
    MODE_WET,
    MODE_RAMP_OUT, // wet -> dry, then bypass
} Mode;

#define FADE_SECONDS 0.02

typedef struct {
    bool positive;
    uint32_t crossings, frames;
} Meter;

struct NavisPitchStage {
    NavisPitchRenderer renderer;
    int channels, maxFrames, fadeFrames, meterWindow;
    float *dry, *wet; // channels * maxFrames each, allocated in _new
    _Atomic int32_t requested;
    // Audio thread only once the stage is published (_new sets the starting
    // values before that).
    Mode mode;
    int32_t applied; // cents the renderer was last given
    float wetGain;   // 0 dry ... 1 wet
    int64_t fed;     // frames given to the renderer since it was last reset
    bool resetLatched;
    Meter in, out;
    // Published for the state reader.
    _Atomic bool active;
    _Atomic uint64_t resets, renderErrors;
    _Atomic uint32_t inputMilliHz, outputMilliHz;
};

static int32_t clampCents(float cents) {
    if (!(cents > -NAVIS_PITCH_MAX_CENTS)) return cents != cents ? 0 : -NAVIS_PITCH_MAX_CENTS;
    if (cents > NAVIS_PITCH_MAX_CENTS) return NAVIS_PITCH_MAX_CENTS;
    return (int32_t)lroundf(cents);
}

NavisPitchStage *navis_pitch_stage_new(const NavisPitchRenderer *renderer, int channels, int maxFrames,
                                       double sampleRate, float initialCents) {
    if (!renderer || !renderer->render || !renderer->reset || !renderer->set_cents
        || channels < 1 || channels > NAVIS_PITCH_MAX_CHANNELS || maxFrames < 1 || !(sampleRate > 0)
        || renderer->latencyFrames < 0) {
        return NULL;
    }
    NavisPitchStage *s = calloc(1, sizeof *s);
    float *scratch = calloc((size_t)channels * (size_t)maxFrames * 2, sizeof(float));
    if (!s || !scratch) {
        free(s);
        free(scratch);
        return NULL;
    }
    s->renderer = *renderer;
    s->channels = channels;
    s->maxFrames = maxFrames;
    s->fadeFrames = (int)lround(FADE_SECONDS * sampleRate);
    if (s->fadeFrames < 1) s->fadeFrames = 1;
    s->meterWindow = (int)lround(sampleRate);
    s->dry = scratch;
    s->wet = scratch + (size_t)channels * (size_t)maxFrames;
    int32_t cents = clampCents(initialCents);
    atomic_init(&s->requested, cents);
    atomic_init(&s->resets, 0);
    atomic_init(&s->renderErrors, 0);
    atomic_init(&s->inputMilliHz, 0);
    atomic_init(&s->outputMilliHz, 0);
    if (cents != 0) {
        renderer->set_cents(renderer->user, (float)cents);
        s->applied = cents;
        s->mode = MODE_WET;
        s->wetGain = 1;
    }
    atomic_init(&s->active, cents != 0);
    return s;
}

void navis_pitch_stage_free(NavisPitchStage *s) {
    if (!s) return;
    free(s->dry); // dry is the start of the one allocation
    free(s);
}

void navis_pitch_stage_request(NavisPitchStage *s, float cents) {
    atomic_store_explicit(&s->requested, clampCents(cents), memory_order_relaxed);
}

void navis_pitch_stage_note_reset(NavisPitchStage *s) { s->resetLatched = true; }

void navis_pitch_stage_state(NavisPitchStage *s, NavisPitchState *out) {
    out->cents = atomic_load_explicit(&s->requested, memory_order_relaxed);
    out->active = atomic_load_explicit(&s->active, memory_order_relaxed);
    out->latencyFrames = s->renderer.latencyFrames;
    out->resetCount = atomic_load_explicit(&s->resets, memory_order_relaxed);
    out->renderErrors = atomic_load_explicit(&s->renderErrors, memory_order_relaxed);
    out->inputHz = (float)atomic_load_explicit(&s->inputMilliHz, memory_order_relaxed) / 1000.0f;
    out->outputHz = (float)atomic_load_explicit(&s->outputMilliHz, memory_order_relaxed) / 1000.0f;
}

// Positive-going zero crossings of one channel over a window of about a second.
static void measure(Meter *m, const float *x, int n, int window, _Atomic uint32_t *published, int rate) {
    for (int i = 0; i < n; i++) {
        bool positive = x[i] > 0;
        if (positive && !m->positive) m->crossings++;
        m->positive = positive;
    }
    m->frames += (uint32_t)n;
    if (m->frames >= (uint32_t)window) {
        double hz = (double)m->crossings * (double)rate / (double)m->frames;
        atomic_store_explicit(published, (uint32_t)(hz * 1000.0), memory_order_relaxed);
        m->crossings = m->frames = 0;
    }
}

static void applyRequest(NavisPitchStage *s) {
    int32_t target = atomic_load_explicit(&s->requested, memory_order_relaxed);
    switch (s->mode) {
    case MODE_BYPASS:
        if (target != 0) { // a user switch on: dry while the renderer fills
            s->renderer.reset(s->renderer.user);
            s->renderer.set_cents(s->renderer.user, (float)target);
            s->applied = target;
            s->fed = 0;
            s->wetGain = 0;
            s->mode = MODE_PRIME;
        }
        break;
    case MODE_PRIME:
        if (target == 0) s->mode = MODE_BYPASS; // nothing wet was ever heard
        break;
    case MODE_RAMP_OUT:
        if (target != 0) s->mode = MODE_RAMP_IN; // changed its mind: back up from where it is
        break;
    default:
        if (target == 0) s->mode = MODE_RAMP_OUT;
        break;
    }
    if (s->mode != MODE_BYPASS && s->mode != MODE_RAMP_OUT && target != 0 && target != s->applied) {
        s->renderer.set_cents(s->renderer.user, (float)target);
        s->applied = target;
    }
    if (s->mode == MODE_PRIME && s->fed >= s->renderer.latencyFrames) s->mode = MODE_RAMP_IN;
}

static void processChunk(NavisPitchStage *s, float *const *ch, int n) {
    applyRequest(s);
    measure(&s->in, ch[0], n, s->meterWindow, &s->inputMilliHz, s->meterWindow);
    if (s->mode == MODE_BYPASS) {
        atomic_store_explicit(&s->active, false, memory_order_relaxed);
        measure(&s->out, ch[0], n, s->meterWindow, &s->outputMilliHz, s->meterWindow);
        return;
    }
    const float *dry[NAVIS_PITCH_MAX_CHANNELS];
    float *wet[NAVIS_PITCH_MAX_CHANNELS];
    for (int c = 0; c < s->channels; c++) {
        float *d = s->dry + (size_t)c * (size_t)s->maxFrames;
        memcpy(d, ch[c], (size_t)n * sizeof(float));
        dry[c] = d;
        wet[c] = s->wet + (size_t)c * (size_t)s->maxFrames;
    }
    if (s->renderer.render(s->renderer.user, dry, wet, s->channels, n) != 0) {
        atomic_fetch_add_explicit(&s->renderErrors, 1, memory_order_relaxed);
        for (int c = 0; c < s->channels; c++) memcpy(wet[c], dry[c], (size_t)n * sizeof(float));
    }
    s->fed += n;
    float step = 1.0f / (float)s->fadeFrames;
    for (int i = 0; i < n; i++) {
        if (s->mode == MODE_RAMP_IN) {
            s->wetGain += step;
            if (s->wetGain >= 1) { s->wetGain = 1; s->mode = MODE_WET; }
        } else if (s->mode == MODE_RAMP_OUT) {
            s->wetGain -= step;
            if (s->wetGain <= 0) { s->wetGain = 0; s->mode = MODE_BYPASS; }
        }
        if (s->mode == MODE_PRIME || s->wetGain <= 0) continue; // the buffer already holds the dry signal
        for (int c = 0; c < s->channels; c++) {
            ch[c][i] = s->wetGain >= 1 ? wet[c][i] : dry[c][i] * (1.0f - s->wetGain) + wet[c][i] * s->wetGain;
        }
    }
    atomic_store_explicit(&s->active, s->mode != MODE_BYPASS, memory_order_relaxed);
    measure(&s->out, ch[0], n, s->meterWindow, &s->outputMilliHz, s->meterWindow);
}

void navis_pitch_stage_process(NavisPitchStage *s, float *const *channels, int channelCount, int frames) {
    if (frames <= 0 || channelCount != s->channels) return;
    if (s->resetLatched) {
        s->resetLatched = false;
        atomic_fetch_add_explicit(&s->resets, 1, memory_order_relaxed);
        s->in = s->out = (Meter){0};
        int32_t target = atomic_load_explicit(&s->requested, memory_order_relaxed);
        // Nothing to drop while the renderer is idle at pitch 0.
        if (s->mode != MODE_BYPASS || target != 0) s->renderer.reset(s->renderer.user);
        s->fed = 0;
        // Wet from the first frame (one latency of silence); no ramp.
        s->mode = MODE_BYPASS;
        s->wetGain = 0;
        if (target != 0) {
            if (target != s->applied) {
                s->renderer.set_cents(s->renderer.user, (float)target);
                s->applied = target;
            }
            s->mode = MODE_WET;
            s->wetGain = 1;
        }
    }
    float *chunk[NAVIS_PITCH_MAX_CHANNELS];
    for (int offset = 0; offset < frames; offset += s->maxFrames) {
        int n = frames - offset < s->maxFrames ? frames - offset : s->maxFrames;
        for (int c = 0; c < channelCount; c++) chunk[c] = channels[c] + offset;
        processChunk(s, chunk, n);
    }
}
