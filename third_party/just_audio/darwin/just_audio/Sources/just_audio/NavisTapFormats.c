#include "NavisTapFormats.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct Slot {
    int rate, channels;             // rate rounded to Hz
    NavisEqStream *eq;
    NavisPitchStage *pitch;         // NULL when the pitch could not be built
    void *au;                       // behind the pitch stage; freed with it
    const char *pitchReason;
    atomic_flag busy;               // a render thread is inside this slot
} Slot;

struct NavisTapFormats {
    pthread_mutex_t lock;
    NavisEqConfig config;                 // guarded by lock
    NavisPitchFactory factory;
    _Atomic int32_t pitchCents;           // requested; seeds a new stage
    // Published with release stores (pointer, then count); the render thread
    // acquires both. Slots are only freed by free-all and the final free, and
    // free-all only runs when no pipeline is live, so no render thread reaches
    // a slot that goes away.
    _Atomic(Slot *) slots[NAVIS_TAP_MAX_FORMATS];
    _Atomic int slotCount;
    _Atomic(Slot *) lastSlot;             // the slot of the last audio block; render thread writes
    Slot *preparedSlot;                   // the latest prepare's slot; guarded by lock
    int live;                             // guarded by lock
    uint64_t prepareCount;                // guarded by lock
    uint64_t retiredFrames, retiredResets, retiredPitchResets, retiredMismatches; // freed slots; guarded by lock
    const char *formatReason, *pitchReason; // guarded by lock
    _Atomic uint64_t unmatchedFrames, overlapBlocks;
    _Atomic bool lastDry;                 // the last audio block passed dry
};

NavisTapFormats *navis_tap_formats_new(const NavisEqConfig *config, int32_t cents, NavisPitchFactory factory) {
    NavisTapFormats *t = calloc(1, sizeof *t);
    if (!t) return NULL;
    pthread_mutex_init(&t->lock, NULL);
    t->config = *config;
    t->factory = factory;
    atomic_init(&t->pitchCents, cents);
    for (int i = 0; i < NAVIS_TAP_MAX_FORMATS; i++) atomic_init(&t->slots[i], NULL);
    atomic_init(&t->slotCount, 0);
    atomic_init(&t->lastSlot, NULL);
    atomic_init(&t->unmatchedFrames, 0);
    atomic_init(&t->overlapBlocks, 0);
    atomic_init(&t->lastDry, false);
    return t;
}

static void slotFree(NavisTapFormats *t, Slot *s) {
    if (!s) return;
    navis_pitch_stage_free(s->pitch);
    if (s->au) t->factory.destroy(s->au);
    navis_eq_stream_free(s->eq);
    free(s);
}

void navis_tap_formats_free(NavisTapFormats *t) {
    if (!t) return;
    int n = atomic_load(&t->slotCount);
    for (int i = 0; i < n; i++) slotFree(t, atomic_load(&t->slots[i]));
    pthread_mutex_destroy(&t->lock);
    free(t);
}

// Not realtime. NULL when the equalizer cannot be built; a slot may lack a pitch.
static Slot *slotNew(NavisTapFormats *t, int key, double rate, int channels, int maxFrames,
                     const NavisEqConfig *config, int32_t cents) {
    Slot *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    atomic_flag_clear(&s->busy);
    s->rate = key;
    s->channels = channels;
    s->eq = navis_eq_stream_new(config, key, channels);
    if (!s->eq) {
        free(s);
        return NULL;
    }
    // The AU and stage touch nothing shared. They exist at 0 cents too, so
    // turning pitch on later never allocates; one seeded with non-zero cents is
    // wet from its first frame.
    NavisPitchRenderer renderer;
    s->au = t->factory.create(rate, channels, maxFrames, &renderer);
    if (s->au) s->pitch = navis_pitch_stage_new(&renderer, channels, maxFrames, rate, (float)cents);
    if (!s->pitch && s->au) {
        t->factory.destroy(s->au);
        s->au = NULL;
    }
    if (!s->pitch) s->pitchReason = "Pitch cannot be applied to this song; it plays at its original pitch.";
    return s;
}

static Slot *slotFind(NavisTapFormats *t, int key, int channels) { // lock held
    int n = atomic_load_explicit(&t->slotCount, memory_order_relaxed);
    for (int i = 0; i < n; i++) {
        Slot *s = atomic_load_explicit(&t->slots[i], memory_order_relaxed);
        if (s->rate == key && s->channels == channels) return s;
    }
    return NULL;
}

// Lock held, nothing running (no pipeline live): empties the set, keeps the
// numbers of the slots for the state, and hands them back to be freed outside
// the lock. lastSlot goes first so nothing reads a slot that is about to be freed.
static int detachAll(NavisTapFormats *t, Slot *out[NAVIS_TAP_MAX_FORMATS]) {
    atomic_store_explicit(&t->lastSlot, NULL, memory_order_release);
    t->preparedSlot = NULL;
    int n = atomic_load_explicit(&t->slotCount, memory_order_relaxed);
    atomic_store_explicit(&t->slotCount, 0, memory_order_release);
    for (int i = 0; i < n; i++) {
        Slot *s = atomic_load_explicit(&t->slots[i], memory_order_relaxed);
        atomic_store_explicit(&t->slots[i], NULL, memory_order_relaxed);
        NavisEqStreamState st;
        navis_eq_stream_state(s->eq, &st);
        t->retiredFrames += st.processedFrames;
        t->retiredResets += st.resetCount;
        if (s->pitch) {
            NavisPitchState ps;
            navis_pitch_stage_state(s->pitch, &ps);
            t->retiredPitchResets += ps.resetCount;
        }
        if (s->au) t->retiredMismatches += t->factory.mismatches(s->au);
        out[i] = s;
    }
    return n;
}

#define REASON_FORMAT "EQ cannot process this audio format; it plays unchanged."
#define REASON_PITCH_FORMAT "Pitch cannot be applied to this audio format; it plays at its original pitch."
#define REASON_FULL "Too many audio formats in this queue; this song plays unchanged."
#define REASON_FULL_PITCH "Too many audio formats in this queue; this song plays at its original pitch."

bool navis_tap_formats_prepare(NavisTapFormats *t, double rate, int channels, int maxFrames, bool planarFloat) {
    int key = (int)lround(rate);
    pthread_mutex_lock(&t->lock);
    t->prepareCount++;
    t->live++;
    t->formatReason = t->pitchReason = NULL;
    if (!planarFloat || channels < 1 || channels > NAVIS_EQ_MAX_CHANNELS || key < 1 || maxFrames < 1) {
        t->formatReason = REASON_FORMAT;
        t->pitchReason = REASON_PITCH_FORMAT;
        t->preparedSlot = NULL;
        pthread_mutex_unlock(&t->lock);
        return false;
    }
    Slot *found = slotFind(t, key, channels);
    if (found) { // reused untouched: no rebuild, no history reset
        t->preparedSlot = found;
        pthread_mutex_unlock(&t->lock);
        return true;
    }
    if (atomic_load_explicit(&t->slotCount, memory_order_relaxed) == NAVIS_TAP_MAX_FORMATS && t->live > 1) {
        t->formatReason = REASON_FULL;
        t->pitchReason = REASON_FULL_PITCH;
        t->preparedSlot = NULL;
        pthread_mutex_unlock(&t->lock);
        return false;
    }
    NavisEqConfig config = t->config;
    int32_t seeded = atomic_load_explicit(&t->pitchCents, memory_order_relaxed);
    pthread_mutex_unlock(&t->lock);

    // Built outside the lock: creating an AudioUnit can take long and the main
    // thread reads the state under it.
    Slot *fresh = slotNew(t, key, rate, channels, maxFrames, &config, seeded);

    Slot *doomed[NAVIS_TAP_MAX_FORMATS];
    int nDoomed = 0;
    bool ok = true;
    pthread_mutex_lock(&t->lock);
    found = slotFind(t, key, channels);
    if (found) { // another prepare of this format won while this one was building
        t->preparedSlot = found;
    } else if (!fresh) {
        t->formatReason = REASON_FORMAT;
        t->pitchReason = REASON_PITCH_FORMAT;
        t->preparedSlot = NULL;
        ok = false;
    } else {
        int n = atomic_load_explicit(&t->slotCount, memory_order_relaxed);
        if (n == NAVIS_TAP_MAX_FORMATS && t->live > 1) {
            t->formatReason = REASON_FULL;
            t->pitchReason = REASON_FULL_PITCH;
            t->preparedSlot = NULL;
            ok = false;
        } else {
            if (n == NAVIS_TAP_MAX_FORMATS) { // no other pipeline is live: start over
                nDoomed = detachAll(t, doomed);
                n = 0;
            }
            // Requests that arrived while the slot was being built found no slot.
            if (!navis_eq_config_same(&config, &t->config)) navis_eq_stream_request(fresh->eq, &t->config);
            int32_t now = atomic_load_explicit(&t->pitchCents, memory_order_relaxed);
            if (fresh->pitch && now != seeded) navis_pitch_stage_request(fresh->pitch, (float)now);
            atomic_store_explicit(&t->slots[n], fresh, memory_order_release);
            atomic_store_explicit(&t->slotCount, n + 1, memory_order_release);
            t->preparedSlot = fresh;
            fresh = NULL;
        }
    }
    pthread_mutex_unlock(&t->lock);
    for (int i = 0; i < nDoomed; i++) slotFree(t, doomed[i]);
    slotFree(t, fresh); // a build that lost the race or could not be used
    return ok;
}

bool navis_tap_formats_unprepare(NavisTapFormats *t) {
    pthread_mutex_lock(&t->lock);
    bool matched = t->live > 0;
    if (matched) t->live--;
    pthread_mutex_unlock(&t->lock);
    return matched;
}

// The slot for a block, or NULL. See the header for the rule.
static Slot *pickSlot(NavisTapFormats *t, int count, int frames, int64_t value, int32_t timescale) {
    int n = atomic_load_explicit(&t->slotCount, memory_order_acquire);
    if (n == 1) {
        Slot *s = atomic_load_explicit(&t->slots[0], memory_order_acquire);
        return s->channels == count ? s : NULL;
    }
    if (value <= 0 || timescale <= 0 || frames <= 0) return NULL;
    double span = (double)frames * (double)timescale;
    double estimate = span / (double)value;
    // The duration is rounded to whole ticks: the true rate lies in this interval.
    double low = span / ((double)value + 1), high = value > 1 ? span / ((double)value - 1) : INFINITY;
    Slot *best = NULL;
    double bestDistance = INFINITY;
    for (int i = 0; i < n; i++) {
        Slot *s = atomic_load_explicit(&t->slots[i], memory_order_acquire);
        if (s->channels != count) continue;
        double distance = fabs((double)s->rate - estimate);
        bool near = distance <= 0.04 * estimate || ((double)s->rate >= low && (double)s->rate <= high);
        if (near && distance < bestDistance) {
            best = s;
            bestDistance = distance;
        }
    }
    return best;
}

void navis_tap_formats_process(NavisTapFormats *t, bool startOfStream, uint32_t flushGeneration,
                               int64_t durationValue, int32_t timescale, float *const *channels,
                               int count, int frames) {
    // Only a block with a valid, non-empty range is audio. Paused, seeking and
    // the first block of a pipeline come with an invalid range.
    bool audio = durationValue > 0 && timescale > 0 && frames > 0;
    Slot *s = pickSlot(t, count, frames, durationValue, timescale);
    if (!s) {
        if (audio) {
            atomic_fetch_add_explicit(&t->unmatchedFrames, (uint64_t)frames, memory_order_relaxed);
            atomic_store_explicit(&t->lastDry, true, memory_order_relaxed);
        }
        return;
    }
    if (atomic_flag_test_and_set_explicit(&s->busy, memory_order_acquire)) {
        if (audio) {
            atomic_fetch_add_explicit(&t->overlapBlocks, 1, memory_order_relaxed);
            atomic_store_explicit(&t->lastDry, true, memory_order_relaxed);
        }
        return;
    }
    int audioFrames = audio ? frames : 0;
    // The stream decides a reset (StartOfStream, or a new flush generation) and the
    // pitch stage is told exactly that; then pitch first and the EQ (as on Android).
    navis_pitch_stage_begin_block(s->pitch, s->eq, startOfStream, flushGeneration, audioFrames);
    if (s->pitch && audioFrames > 0) navis_pitch_stage_process(s->pitch, channels, count, frames);
    navis_eq_stream_process(s->eq, channels, count, frames);
    if (audio) {
        atomic_store_explicit(&t->lastSlot, s, memory_order_release);
        atomic_store_explicit(&t->lastDry, false, memory_order_relaxed);
    }
    atomic_flag_clear_explicit(&s->busy, memory_order_release);
}

void navis_tap_formats_configure(NavisTapFormats *t, const NavisEqConfig *config) {
    pthread_mutex_lock(&t->lock);
    t->config = *config;
    int n = atomic_load_explicit(&t->slotCount, memory_order_relaxed);
    // Banks are built here, off the audio thread; each slot swaps at a block boundary.
    for (int i = 0; i < n; i++) navis_eq_stream_request(atomic_load_explicit(&t->slots[i], memory_order_relaxed)->eq, config);
    pthread_mutex_unlock(&t->lock);
}

void navis_tap_formats_set_cents(NavisTapFormats *t, int32_t cents) {
    pthread_mutex_lock(&t->lock);
    atomic_store_explicit(&t->pitchCents, cents, memory_order_relaxed);
    int n = atomic_load_explicit(&t->slotCount, memory_order_relaxed);
    for (int i = 0; i < n; i++) {
        Slot *s = atomic_load_explicit(&t->slots[i], memory_order_relaxed);
        if (s->pitch) navis_pitch_stage_request(s->pitch, (float)cents);
    }
    pthread_mutex_unlock(&t->lock);
}

void navis_tap_formats_state(NavisTapFormats *t, NavisTapFormatsState *out) {
    memset(out, 0, sizeof *out);
    pthread_mutex_lock(&t->lock);
    int n = atomic_load_explicit(&t->slotCount, memory_order_relaxed);
    Slot *report = atomic_load_explicit(&t->lastSlot, memory_order_acquire);
    bool played = report != NULL;
    if (!report) report = t->preparedSlot;
    out->slotCount = n;
    out->live = t->live;
    out->prepareCount = t->prepareCount;
    out->unmatchedFrames = atomic_load_explicit(&t->unmatchedFrames, memory_order_relaxed);
    out->overlapBlocks = atomic_load_explicit(&t->overlapBlocks, memory_order_relaxed);
    out->processedFrames = t->retiredFrames;
    out->resetCount = t->retiredResets;
    out->pitchResetCount = t->retiredPitchResets;
    out->pitchPullMismatches = t->retiredMismatches;
    for (int i = 0; i < n; i++) {
        Slot *s = atomic_load_explicit(&t->slots[i], memory_order_relaxed);
        navis_eq_stream_sweep(s->eq);
        NavisEqStreamState st;
        navis_eq_stream_state(s->eq, &st);
        NavisPitchState ps = {0};
        if (s->pitch) navis_pitch_stage_state(s->pitch, &ps);
        out->processedFrames += st.processedFrames;
        out->resetCount += st.resetCount;
        out->pitchResetCount += ps.resetCount;
        if (s->au) out->pitchPullMismatches += t->factory.mismatches(s->au);
        out->formats[i] = (NavisTapFormatInfo){
            .sampleRate = s->rate, .channels = s->channels, .processedFrames = st.processedFrames,
            .resetCount = st.resetCount, .pitchResetCount = ps.resetCount,
            .hasLevel = st.hasLevel, .levelDeltaDb = st.levelDeltaDb,
        };
        if (s == report) {
            out->hasStream = true;
            out->stream = st;
            if (s->pitch) {
                out->hasPitch = true;
                out->pitch = ps;
                // A stage that is idle (paused, or between songs) has not yet seen a
                // request to stop; it is not pitching what it was asked not to.
                out->pitch.active = ps.active && ps.cents != 0;
            }
            out->pitchReason = s->pitch ? NULL : s->pitchReason;
        }
    }
    bool dry = atomic_load_explicit(&t->lastDry, memory_order_relaxed);
    if (t->formatReason && (!played || dry)) {
        out->formatReason = t->formatReason;
        if (t->pitchReason) out->pitchReason = t->pitchReason;
    }
    pthread_mutex_unlock(&t->lock);
}
