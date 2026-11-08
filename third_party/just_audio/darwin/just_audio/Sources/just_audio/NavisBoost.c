#include "NavisBoost.h"

#include <math.h>

// MARK: decision

static double clampDb(double db) {
    if (!(db > 0)) return 0; // NaN, zero and negative
    return db > NAVIS_BOOST_MAX_DB ? NAVIS_BOOST_MAX_DB : db;
}

static double lower(double a, double b) { return a < b ? a : b; }

void navis_boost_decide(const NavisBoostInput *in, int windowMs, NavisBoostOutput *out) {
    double own = clampDb(in->ownDb);
    double next = isnan(in->nextDb) ? own : clampDb(in->nextDb);
    double speed = in->speed > 0 && isfinite(in->speed) ? in->speed : 1;
    double duration = NAN; // the smaller known duration
    if (isfinite(in->playerDurationMs) && in->playerDurationMs > 0) duration = in->playerDurationMs;
    if (isfinite(in->tagDurationMs) && in->tagDurationMs > 0 && !(in->tagDurationMs >= duration)) duration = in->tagDurationMs;
    bool unknown = !isfinite(duration) || !isfinite(in->positionMs);
    bool guarded = in->latched || unknown || duration < windowMs + 1000
                   || (duration - in->positionMs) / speed <= windowMs;
    double db = guarded ? lower(own, next) : own;
    // The latch and the hold both bound the value by the one in force.
    if (in->latched || in->held) db = lower(db, clampDb(in->previousDb));
    out->targetDb = db;
    out->guarded = guarded;
    // Unknown timing guards but does not latch: it lasts only until the item is ready, and a latch
    // taken then would hold the song at min(own, next) for the whole song.
    out->latched = guarded && !unknown;
}

float navis_boost_linear(double db) {
    if (!(db > 0)) return 1.0f;
    return (float)pow(10.0, clampDb(db) / 20.0);
}

// MARK: ramp

static float clampTarget(float target) {
    if (!(target >= 1.0f)) return 1.0f; // NaN and a cut
    return target > NAVIS_BOOST_MAX_LINEAR ? NAVIS_BOOST_MAX_LINEAR : target;
}

void navis_boost_ramp_init(NavisBoostRamp *r, int sampleRate) {
    r->rampFrames = sampleRate / 50 > 1 ? sampleRate / 50 : 1;
    r->gain = r->target = r->start = 1.0f;
    r->step = 0;
    r->remaining = 0;
    r->primed = false;
}

void navis_boost_ramp_snap(NavisBoostRamp *r, float target) {
    r->gain = r->target = r->start = clampTarget(target);
    r->step = 0;
    r->remaining = 0;
    r->primed = true;
}

void navis_boost_ramp_process(NavisBoostRamp *r, float *const *channels, int count, int frames, float target,
                              uint64_t *clipCount) {
    if (frames <= 0) return;
    target = clampTarget(target);
    if (!r->primed) navis_boost_ramp_snap(r, target);
    if (target != r->target) {
        r->target = target;
        r->start = r->gain;
        r->step = (target - r->gain) / (float)r->rampFrames;
        r->remaining = r->rampFrames;
    }
    if (r->remaining == 0 && r->gain == 1.0f) return; // unity: bit-exact, nothing can clip
    float endGain = r->gain;
    int endRemaining = r->remaining;
    uint64_t clipped = 0;
    for (int c = 0; c < count; c++) {
        float *x = channels[c];
        float gain = r->gain;
        int remaining = r->remaining;
        for (int i = 0; i < frames; i++) {
            if (remaining > 0) {
                remaining--;
                gain = remaining == 0 ? r->target : r->start + r->step * (float)(r->rampFrames - remaining);
            }
            float y = x[i] * gain;
            x[i] = y;
            if (gain > 1.0f && fabsf(y) > 1.0f) clipped++;
        }
        endGain = gain;
        endRemaining = remaining;
    }
    r->gain = endGain; // every channel ends on the same gain
    r->remaining = endRemaining;
    *clipCount += clipped;
}
