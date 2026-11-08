// TEMPORARY (red step of I25): today's single-stream behaviour behind the new
// API, so the tests fail on assertions about the cause: the last prepare wins,
// unprepare frees the stream, process uses whatever stream is there at its
// own format. Replaced by the real implementation in the next commit.
#include "NavisTapFormats.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct NavisTapFormats {
    pthread_mutex_t lock;
    NavisEqConfig config;
    NavisPitchFactory factory;
    int32_t cents;
    NavisEqStream *eq;
    NavisPitchStage *pitch;
    void *au;
    int rate, channels;
    int live;
    uint64_t prepareCount, retiredFrames, unmatched;
};

NavisTapFormats *navis_tap_formats_new(const NavisEqConfig *config, int32_t cents, NavisPitchFactory factory) {
    NavisTapFormats *t = calloc(1, sizeof *t);
    pthread_mutex_init(&t->lock, NULL);
    t->config = *config;
    t->cents = cents;
    t->factory = factory;
    return t;
}

static void drop(NavisTapFormats *t) {
    if (t->eq) {
        NavisEqStreamState st;
        navis_eq_stream_state(t->eq, &st);
        t->retiredFrames += st.processedFrames;
    }
    navis_pitch_stage_free(t->pitch);
    if (t->au) t->factory.destroy(t->au);
    navis_eq_stream_free(t->eq);
    t->eq = NULL;
    t->pitch = NULL;
    t->au = NULL;
}

void navis_tap_formats_free(NavisTapFormats *t) {
    drop(t);
    pthread_mutex_destroy(&t->lock);
    free(t);
}

bool navis_tap_formats_prepare(NavisTapFormats *t, double rate, int channels, int maxFrames, bool planarFloat) {
    pthread_mutex_lock(&t->lock);
    drop(t);
    t->live++;
    t->prepareCount++;
    if (planarFloat) {
        t->rate = (int)(rate + 0.5);
        t->channels = channels;
        t->eq = navis_eq_stream_new(&t->config, t->rate, channels);
        NavisPitchRenderer renderer;
        t->au = t->factory.create(rate, channels, maxFrames, &renderer);
        if (t->au) t->pitch = navis_pitch_stage_new(&renderer, channels, maxFrames, rate, (float)t->cents);
    }
    pthread_mutex_unlock(&t->lock);
    return t->eq != NULL;
}

bool navis_tap_formats_unprepare(NavisTapFormats *t) {
    pthread_mutex_lock(&t->lock);
    bool matched = t->live > 0;
    if (matched) t->live--;
    drop(t);
    pthread_mutex_unlock(&t->lock);
    return matched;
}

void navis_tap_formats_process(NavisTapFormats *t, bool startOfStream, uint32_t flushGeneration,
                               int64_t durationValue, int32_t timescale, float *const *channels,
                               int count, int frames) {
    if (!t->eq) {
        if (durationValue > 0 && timescale > 0) t->unmatched += (uint64_t)frames;
        return;
    }
    int audioFrames = durationValue > 0 && timescale > 0 ? frames : 0;
    navis_pitch_stage_begin_block(t->pitch, t->eq, startOfStream, flushGeneration, audioFrames);
    if (t->pitch && audioFrames > 0) navis_pitch_stage_process(t->pitch, channels, count, frames);
    navis_eq_stream_process(t->eq, channels, count, frames);
}

void navis_tap_formats_configure(NavisTapFormats *t, const NavisEqConfig *config) {
    pthread_mutex_lock(&t->lock);
    t->config = *config;
    if (t->eq) navis_eq_stream_request(t->eq, config);
    pthread_mutex_unlock(&t->lock);
}

void navis_tap_formats_set_cents(NavisTapFormats *t, int32_t cents) {
    pthread_mutex_lock(&t->lock);
    t->cents = cents;
    if (t->pitch) navis_pitch_stage_request(t->pitch, (float)cents);
    pthread_mutex_unlock(&t->lock);
}

void navis_tap_formats_state(NavisTapFormats *t, NavisTapFormatsState *out) {
    memset(out, 0, sizeof *out);
    pthread_mutex_lock(&t->lock);
    out->live = t->live;
    out->prepareCount = t->prepareCount;
    out->unmatchedFrames = t->unmatched;
    out->processedFrames = t->retiredFrames;
    if (t->eq) {
        out->slotCount = 1;
        out->hasStream = true;
        navis_eq_stream_state(t->eq, &out->stream);
        out->processedFrames += out->stream.processedFrames;
        out->formats[0] = (NavisTapFormatInfo){.sampleRate = t->rate, .channels = t->channels,
                                               .processedFrames = out->stream.processedFrames};
    }
    pthread_mutex_unlock(&t->lock);
}
