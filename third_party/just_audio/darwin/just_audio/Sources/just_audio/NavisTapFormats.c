#include "NavisTapFormats.h"

#include "NavisBoost.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct Slot {
    int rate, channels;             // rate rounded to Hz
    NavisEqStream *eq;
    // NULL when the pitch could not be built; a later prepare of the format builds
    // it again and publishes it here (release), the render thread loads it once per block.
    _Atomic(NavisPitchStage *) pitch;
    void *au;                       // behind the pitch stage; freed with it; guarded by lock
    const char *pitchReason;        // why there is no pitch stage; guarded by lock
    atomic_flag busy;               // a render thread is inside this slot
    // A StartOfStream block dropped because the slot was busy; the next block
    // processed on the slot acts on it.
    _Atomic bool pendingStart;
    // The ReplayGain boost (I24): the render thread owns the ramp, the busy flag
    // serialises it; the gain it ended the last block on is published for the state.
    NavisBoostRamp boost;
    bool boostAudioSeen;            // render thread: the boost saw a block of audio (not just empty ranges)
    _Atomic float appliedGain;
} Slot;

// Why a prepare gave no slot; shown while a song plays unchanged.
enum { REASON_NONE = 0, REASON_FORMAT, REASON_FULL };

struct NavisTapFormats {
    pthread_mutex_t lock;
    NavisEqConfig config;                 // guarded by lock
    NavisPitchFactory factory;
    _Atomic int32_t pitchCents;           // requested; seeds a new stage
    // The boost as a linear gain (1 = none), written by the main thread, read by every slot's
    // render thread once per block. Lock-free; the main thread does the pow.
    _Atomic float boostTarget;
    _Atomic uint64_t boostClipSamples;    // samples beyond full scale after the boost gain
    // Published with release stores (pointer, then count); the render thread
    // acquires both. Slots are only freed by free-all and the final free, and
    // free-all only runs when no pipeline is live, so no render thread reaches
    // a slot that goes away.
    _Atomic(Slot *) slots[NAVIS_TAP_MAX_FORMATS];
    _Atomic int slotCount;
    _Atomic(Slot *) lastSlot;             // the slot of the last audio block; render thread writes
    // The slot of the latest prepare: the pipeline that has just started, whose
    // first block has no usable rate. Written under lock, read by the render thread.
    _Atomic(Slot *) preparedSlot;
    int live;                             // guarded by lock
    uint64_t prepareCount, unprepareCount, clampedCount; // guarded by lock
    uint64_t retiredFrames, retiredResets, retiredPitchResets, retiredMismatches; // freed slots; guarded by lock
    // The failure of the latest prepare if it gave no slot, and the reason
    // shown now: set by that prepare, cleared when a block is processed by a slot,
    // set again by a block that passes unchanged. Plain atomics: the render thread writes them.
    _Atomic int failure, reason;
    _Atomic uint64_t unmatchedFrames, overlapBlocks;
    _Atomic bool lastDry;                 // the last block passed unchanged
};

NavisTapFormats *navis_tap_formats_new(const NavisEqConfig *config, int32_t cents, NavisPitchFactory factory) {
    NavisTapFormats *t = calloc(1, sizeof *t);
    if (!t) return NULL;
    pthread_mutex_init(&t->lock, NULL);
    t->config = *config;
    t->factory = factory;
    atomic_init(&t->pitchCents, cents);
    atomic_init(&t->boostTarget, 1.0f);
    atomic_init(&t->boostClipSamples, 0);
    for (int i = 0; i < NAVIS_TAP_MAX_FORMATS; i++) atomic_init(&t->slots[i], NULL);
    atomic_init(&t->slotCount, 0);
    atomic_init(&t->lastSlot, NULL);
    atomic_init(&t->preparedSlot, NULL);
    atomic_init(&t->failure, REASON_NONE);
    atomic_init(&t->reason, REASON_NONE);
    atomic_init(&t->unmatchedFrames, 0);
    atomic_init(&t->overlapBlocks, 0);
    atomic_init(&t->lastDry, false);
    return t;
}

static void slotFree(NavisTapFormats *t, Slot *s) {
    if (!s) return;
    navis_pitch_stage_free(atomic_load(&s->pitch));
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

#define PITCH_REASON "Pitch cannot be applied to this song; it plays at its original pitch."

// Not realtime. The AU and its stage touch nothing shared. They exist at 0 cents
// too, so turning pitch on later never allocates; one built at non-zero cents is
// wet from its first frame. NULL when either cannot be built (nothing is leaked).
static NavisPitchStage *pitchBuild(NavisTapFormats *t, double rate, int channels, int maxFrames, int32_t cents,
                                   void **auOut) {
    NavisPitchRenderer renderer;
    void *au = t->factory.create(rate, channels, maxFrames, &renderer);
    if (!au) return NULL;
    NavisPitchStage *stage = navis_pitch_stage_new(&renderer, channels, maxFrames, rate, (float)cents);
    if (!stage) {
        t->factory.destroy(au);
        return NULL;
    }
    *auOut = au;
    return stage;
}

// Not realtime. NULL when the equalizer cannot be built; a slot may lack a pitch.
static Slot *slotNew(NavisTapFormats *t, int key, double rate, int channels, int maxFrames,
                     const NavisEqConfig *config, int32_t cents) {
    Slot *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    atomic_flag_clear(&s->busy);
    atomic_init(&s->pendingStart, false);
    navis_boost_ramp_init(&s->boost, key);
    atomic_init(&s->appliedGain, 1.0f);
    s->rate = key;
    s->channels = channels;
    s->eq = navis_eq_stream_new(config, key, channels);
    if (!s->eq) {
        free(s);
        return NULL;
    }
    NavisPitchStage *pitch = pitchBuild(t, rate, channels, maxFrames, cents, &s->au);
    atomic_init(&s->pitch, pitch);
    if (!pitch) s->pitchReason = PITCH_REASON;
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
    atomic_store_explicit(&t->preparedSlot, NULL, memory_order_release);
    // Starting over settles whatever the failed prepare was about.
    atomic_store_explicit(&t->failure, REASON_NONE, memory_order_relaxed);
    atomic_store_explicit(&t->reason, REASON_NONE, memory_order_relaxed);
    int n = atomic_load_explicit(&t->slotCount, memory_order_relaxed);
    atomic_store_explicit(&t->slotCount, 0, memory_order_release);
    for (int i = 0; i < n; i++) {
        Slot *s = atomic_load_explicit(&t->slots[i], memory_order_relaxed);
        atomic_store_explicit(&t->slots[i], NULL, memory_order_relaxed);
        NavisEqStreamState st;
        navis_eq_stream_state(s->eq, &st);
        t->retiredFrames += st.processedFrames;
        t->retiredResets += st.resetCount;
        NavisPitchStage *pitch = atomic_load(&s->pitch);
        if (pitch) {
            NavisPitchState ps;
            navis_pitch_stage_state(pitch, &ps);
            t->retiredPitchResets += ps.resetCount;
        }
        if (s->au) t->retiredMismatches += t->factory.mismatches(s->au);
        out[i] = s;
    }
    return n;
}

#define REASON_FORMAT_TEXT "EQ cannot process this audio format; it plays unchanged."
#define REASON_PITCH_FORMAT_TEXT "Pitch cannot be applied to this audio format; it plays at its original pitch."
#define REASON_FULL_TEXT "Too many audio formats in this queue; this song plays unchanged."
#define REASON_PITCH_FULL_TEXT "Too many audio formats in this queue; this song plays at its original pitch."

static void prepareFailed(NavisTapFormats *t, int why) { // lock held
    atomic_store_explicit(&t->failure, why, memory_order_relaxed);
    atomic_store_explicit(&t->reason, why, memory_order_relaxed);
    atomic_store_explicit(&t->preparedSlot, NULL, memory_order_release);
}

// A prepare found its format's slot without a pitch stage (an earlier build failed):
// build the AU and stage outside the lock, then publish them as for a new slot.
static void pitchRebuild(NavisTapFormats *t, Slot *s, double rate, int channels, int maxFrames, int32_t seeded) {
    void *au = NULL;
    NavisPitchStage *stage = pitchBuild(t, rate, channels, maxFrames, seeded, &au);
    if (!stage) return;
    pthread_mutex_lock(&t->lock);
    // The slot cannot have been freed: this pipeline is live, and free-all needs none.
    bool wanted = atomic_load_explicit(&s->pitch, memory_order_relaxed) == NULL;
    if (wanted) {
        s->au = au;
        s->pitchReason = NULL;
        int32_t now = atomic_load_explicit(&t->pitchCents, memory_order_relaxed);
        if (now != seeded) navis_pitch_stage_request(stage, (float)now);
        atomic_store_explicit(&s->pitch, stage, memory_order_release);
    }
    pthread_mutex_unlock(&t->lock);
    if (!wanted) { // another prepare of this format won
        navis_pitch_stage_free(stage);
        t->factory.destroy(au);
    }
}

bool navis_tap_formats_prepare(NavisTapFormats *t, double rate, int channels, int maxFrames, bool planarFloat) {
    int key = (int)lround(rate);
    pthread_mutex_lock(&t->lock);
    t->prepareCount++;
    t->live++;
    if (!planarFloat || channels < 1 || channels > NAVIS_EQ_MAX_CHANNELS || key < 1 || maxFrames < 1) {
        prepareFailed(t, REASON_FORMAT);
        pthread_mutex_unlock(&t->lock);
        return false;
    }
    Slot *found = slotFind(t, key, channels);
    if (found) { // reused untouched: no rebuild, no history reset
        atomic_store_explicit(&t->preparedSlot, found, memory_order_release);
        atomic_store_explicit(&t->failure, REASON_NONE, memory_order_relaxed); // a later prepare succeeded
        bool rebuild = atomic_load_explicit(&found->pitch, memory_order_relaxed) == NULL;
        int32_t seeded = atomic_load_explicit(&t->pitchCents, memory_order_relaxed);
        pthread_mutex_unlock(&t->lock);
        if (rebuild) pitchRebuild(t, found, rate, channels, maxFrames, seeded);
        return true;
    }
    if (atomic_load_explicit(&t->slotCount, memory_order_relaxed) == NAVIS_TAP_MAX_FORMATS && t->live > 1) {
        prepareFailed(t, REASON_FULL);
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
    bool rebuild = false;
    pthread_mutex_lock(&t->lock);
    found = slotFind(t, key, channels);
    if (found) { // another prepare of this format won while this one was building
        atomic_store_explicit(&t->preparedSlot, found, memory_order_release);
        atomic_store_explicit(&t->failure, REASON_NONE, memory_order_relaxed); // a later prepare succeeded
        rebuild = atomic_load_explicit(&found->pitch, memory_order_relaxed) == NULL;
    } else if (!fresh) {
        prepareFailed(t, REASON_FORMAT);
        ok = false;
    } else {
        int n = atomic_load_explicit(&t->slotCount, memory_order_relaxed);
        if (n == NAVIS_TAP_MAX_FORMATS && t->live > 1) {
            prepareFailed(t, REASON_FULL);
            ok = false;
        } else {
            if (n == NAVIS_TAP_MAX_FORMATS) { // no other pipeline is live: start over
                nDoomed = detachAll(t, doomed);
                n = 0;
            }
            // Requests that arrived while the slot was being built found no slot.
            if (!navis_eq_config_same(&config, &t->config)) navis_eq_stream_request(fresh->eq, &t->config);
            int32_t now = atomic_load_explicit(&t->pitchCents, memory_order_relaxed);
            NavisPitchStage *pitch = atomic_load_explicit(&fresh->pitch, memory_order_relaxed);
            if (pitch && now != seeded) navis_pitch_stage_request(pitch, (float)now);
            atomic_store_explicit(&t->slots[n], fresh, memory_order_release);
            atomic_store_explicit(&t->slotCount, n + 1, memory_order_release);
            atomic_store_explicit(&t->preparedSlot, fresh, memory_order_release);
            atomic_store_explicit(&t->failure, REASON_NONE, memory_order_relaxed); // a later prepare succeeded
            fresh = NULL;
        }
    }
    pthread_mutex_unlock(&t->lock);
    for (int i = 0; i < nDoomed; i++) slotFree(t, doomed[i]);
    slotFree(t, fresh); // a build that lost the race or could not be used
    if (rebuild) pitchRebuild(t, found, rate, channels, maxFrames, seeded);
    return ok;
}

bool navis_tap_formats_unprepare(NavisTapFormats *t) {
    pthread_mutex_lock(&t->lock);
    t->unprepareCount++;
    bool matched = t->live > 0;
    if (matched) t->live--;
    else t->clampedCount++;
    pthread_mutex_unlock(&t->lock);
    return matched;
}

// The slot for a block, or NULL. See the header for the rule.
static Slot *pickSlot(NavisTapFormats *t, int count, int frames, int64_t value, int32_t timescale) {
    int n = atomic_load_explicit(&t->slotCount, memory_order_acquire);
    if (n == 0) return NULL;
    if (n == 1) {
        Slot *s = atomic_load_explicit(&t->slots[0], memory_order_acquire);
        return s->channels == count ? s : NULL;
    }
    if (frames <= 0) return NULL;
    Slot *prepared = atomic_load_explicit(&t->preparedSlot, memory_order_acquire);
    if (value <= 0 || timescale <= 0) { // no rate: the first block of a pipeline, which has just prepared
        return prepared && prepared->channels == count ? prepared : NULL;
    }
    double span = (double)frames * (double)timescale;
    double estimate = span / (double)value;
    // The duration is rounded to whole ticks: the true rate lies in this interval.
    double low = span / ((double)value + 1), high = value > 1 ? span / ((double)value - 1) : INFINITY;
    Slot *last = atomic_load_explicit(&t->lastSlot, memory_order_acquire);
    Slot *best = NULL;
    double bestDistance = INFINITY;
    int admitted = 0;
    bool lastAdmitted = false, preparedAdmitted = false;
    for (int i = 0; i < n; i++) {
        Slot *s = atomic_load_explicit(&t->slots[i], memory_order_acquire);
        if (s->channels != count) continue;
        double distance = fabs((double)s->rate - estimate);
        bool near = distance <= 0.04 * estimate || ((double)s->rate >= low && (double)s->rate <= high);
        if (!near) continue;
        admitted++;
        lastAdmitted = lastAdmitted || s == last;
        preparedAdmitted = preparedAdmitted || s == prepared;
        if (distance < bestDistance) {
            best = s;
            bestDistance = distance;
        }
    }
    // A coarse clock can admit several rates. A song that is playing stays on its slot, a
    // pipeline that has just started takes its own, else the nearest.
    if (admitted > 1) {
        if (lastAdmitted) return last;
        if (preparedAdmitted) return prepared;
    }
    return best;
}

// A block that passes unchanged: remember why. The reason of the failed prepare, if
// that is still what keeps this song from a slot, else the generic one.
static void noteDry(NavisTapFormats *t) {
    atomic_store_explicit(&t->lastDry, true, memory_order_relaxed);
    if (atomic_load_explicit(&t->reason, memory_order_relaxed) == REASON_NONE) {
        int why = atomic_load_explicit(&t->failure, memory_order_relaxed);
        atomic_store_explicit(&t->reason, why != REASON_NONE ? why : REASON_FORMAT, memory_order_relaxed);
    }
}

bool navis_tap_format_is_planar_float(bool linearPcm, bool isFloat, bool nonInterleaved,
                                      uint32_t bitsPerChannel, uint32_t channels) {
    return linearPcm && isFloat && nonInterleaved && bitsPerChannel == 32
        && channels >= 1 && channels <= NAVIS_EQ_MAX_CHANNELS;
}

bool navis_tap_buffer_count_ok(uint32_t count) {
    return count >= 1 && count <= NAVIS_EQ_MAX_CHANNELS;
}

bool navis_tap_buffer_ok(uint32_t numberChannels, uint32_t dataByteSize, int64_t frames) {
    // A negative count wraps to a huge size and fails the size check, as before.
    return numberChannels == 1 && dataByteSize >= (uint64_t)frames * sizeof(float);
}

void navis_tap_formats_note_dry(NavisTapFormats *t, int frames) {
    if (frames > 0) noteDry(t);
}

void navis_tap_formats_process(NavisTapFormats *t, bool startOfStream, uint32_t flushGeneration,
                               int64_t durationValue, int32_t timescale, float *const *channels,
                               int count, int frames) {
    // Only a block with a valid, non-empty range is audio. Paused, seeking and
    // the first block of a pipeline come with an invalid range.
    bool audio = durationValue > 0 && timescale > 0 && frames > 0;
    Slot *s = pickSlot(t, count, frames, durationValue, timescale);
    if (!s) {
        if (frames > 0) {
            atomic_fetch_add_explicit(&t->unmatchedFrames, (uint64_t)frames, memory_order_relaxed);
            noteDry(t);
        }
        return;
    }
    if (atomic_flag_test_and_set_explicit(&s->busy, memory_order_acquire)) {
        // Another render thread is in this slot. The block plays unchanged, but its
        // StartOfStream is kept for the next block the slot processes.
        if (startOfStream) atomic_store_explicit(&s->pendingStart, true, memory_order_release);
        if (audio) {
            atomic_fetch_add_explicit(&t->overlapBlocks, 1, memory_order_relaxed);
            noteDry(t);
        }
        return;
    }
    if (atomic_load_explicit(&s->pendingStart, memory_order_relaxed)
        && atomic_exchange_explicit(&s->pendingStart, false, memory_order_acquire)) {
        startOfStream = true;
    }
    int audioFrames = audio ? frames : 0;
    NavisPitchStage *pitch = atomic_load_explicit(&s->pitch, memory_order_acquire);
    // The stream decides a reset (StartOfStream, or a new flush generation) and the
    // pitch stage is told exactly that; then pitch first and the EQ (as on Android).
    bool reset = navis_pitch_stage_begin_block(pitch, s->eq, startOfStream, flushGeneration, audioFrames);
    if (pitch && audioFrames > 0) navis_pitch_stage_process(pitch, channels, count, frames);
    navis_eq_stream_process(s->eq, channels, count, frames);
    if (frames > 0) {
        // The boost comes last, on the output of pitch and EQ. A flush or a new pipeline is
        // already a discontinuity, so it starts at the target with no ramp; any other change of
        // target ramps over 20 ms. A block that passes dry (no slot, busy) gets no boost.
        float target = atomic_load_explicit(&t->boostTarget, memory_order_relaxed);
        // The first block of audio snaps too: blocks without a range can prime the slot before it,
        // and the stream has no history to reset then, so no reset is decided for that block.
        if (reset || startOfStream || (audioFrames > 0 && !s->boostAudioSeen)) navis_boost_ramp_snap(&s->boost, target);
        if (audioFrames > 0) s->boostAudioSeen = true;
        uint64_t clipped = 0;
        navis_boost_ramp_process(&s->boost, channels, count, frames, target, &clipped);
        if (clipped) atomic_fetch_add_explicit(&t->boostClipSamples, clipped, memory_order_relaxed);
        atomic_store_explicit(&s->appliedGain, s->boost.gain, memory_order_relaxed);
    }
    if (audio) {
        atomic_store_explicit(&t->lastSlot, s, memory_order_release);
        atomic_store_explicit(&t->lastDry, false, memory_order_relaxed);
        if (atomic_load_explicit(&t->reason, memory_order_relaxed) != REASON_NONE) {
            atomic_store_explicit(&t->reason, REASON_NONE, memory_order_relaxed);
        }
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
        NavisPitchStage *pitch = atomic_load_explicit(&s->pitch, memory_order_relaxed);
        if (pitch) navis_pitch_stage_request(pitch, (float)cents);
    }
    pthread_mutex_unlock(&t->lock);
}

void navis_tap_formats_set_boost(NavisTapFormats *t, float linear) {
    atomic_store_explicit(&t->boostTarget, linear, memory_order_relaxed);
}

void navis_tap_formats_state(NavisTapFormats *t, NavisTapFormatsState *out) {
    memset(out, 0, sizeof *out);
    pthread_mutex_lock(&t->lock);
    int n = atomic_load_explicit(&t->slotCount, memory_order_relaxed);
    Slot *report = atomic_load_explicit(&t->lastSlot, memory_order_acquire);
    bool played = report != NULL;
    if (!report) report = atomic_load_explicit(&t->preparedSlot, memory_order_acquire);
    out->slotCount = n;
    out->livePipelines = t->live;
    out->prepareCalls = t->prepareCount;
    out->unprepareCalls = t->unprepareCount;
    out->clampedUnprepares = t->clampedCount;
    out->unmatchedFrames = atomic_load_explicit(&t->unmatchedFrames, memory_order_relaxed);
    out->overlapBlocks = atomic_load_explicit(&t->overlapBlocks, memory_order_relaxed);
    out->processedFrames = t->retiredFrames;
    out->resetCount = t->retiredResets;
    out->pitchResetCount = t->retiredPitchResets;
    out->pitchPullMismatches = t->retiredMismatches;
    out->boostClipSamples = atomic_load_explicit(&t->boostClipSamples, memory_order_relaxed);
    out->boostAppliedGain = report ? atomic_load_explicit(&report->appliedGain, memory_order_relaxed) : 1.0f;
    for (int i = 0; i < n; i++) {
        Slot *s = atomic_load_explicit(&t->slots[i], memory_order_relaxed);
        navis_eq_stream_sweep(s->eq);
        NavisEqStreamState st;
        navis_eq_stream_state(s->eq, &st);
        NavisPitchStage *pitch = atomic_load_explicit(&s->pitch, memory_order_acquire);
        NavisPitchState ps = {0};
        if (pitch) navis_pitch_stage_state(pitch, &ps);
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
            if (pitch) {
                out->hasPitch = true;
                out->pitch = ps;
                // A stage that is idle (paused, or between songs) has not yet seen a
                // request to stop; it is not pitching what it was asked not to.
                out->pitch.active = ps.active && ps.cents != 0;
            }
            out->pitchReason = pitch ? NULL : s->pitchReason;
        }
    }
    int why = atomic_load_explicit(&t->reason, memory_order_relaxed);
    bool dry = atomic_load_explicit(&t->lastDry, memory_order_relaxed);
    if (why != REASON_NONE && (!played || dry)) {
        out->formatReason = why == REASON_FULL ? REASON_FULL_TEXT : REASON_FORMAT_TEXT;
        out->pitchReason = why == REASON_FULL ? REASON_PITCH_FULL_TEXT : REASON_PITCH_FORMAT_TEXT;
    }
    pthread_mutex_unlock(&t->lock);
}
