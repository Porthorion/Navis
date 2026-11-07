#include "NavisEqualizerDsp.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define NAVIS_PI 3.14159265358979323846

static const char *const kUnsupportedRate = "EQ frequency exceeds this audio format's sample rate.";

// MARK: Validation

int navis_eq_filter_type_from_name(const char *name) {
    if (!name) return -1;
    static const char *const names[] = {"peaking", "lowShelf", "highShelf", "lowPass", "highPass", "notch"};
    for (int i = 0; i < 6; i++) {
        if (strcmp(name, names[i]) == 0) return i;
    }
    return -1;
}

bool navis_eq_filter_valid(const NavisEqFilter *f) {
    return f && f->type >= NAVIS_EQ_PEAKING && f->type <= NAVIS_EQ_NOTCH
        && isfinite(f->frequency) && f->frequency >= 20 && f->frequency <= 20000
        && isfinite(f->gain) && f->gain >= -24 && f->gain <= 24
        && isfinite(f->q) && f->q >= 0.1 && f->q <= 20;
}

bool navis_eq_config_valid(const NavisEqConfig *c) {
    if (!c || !isfinite(c->preamp) || c->preamp < -60 || c->preamp > 24
        || c->filterCount < 0 || c->filterCount > NAVIS_EQ_MAX_FILTERS) return false;
    for (int i = 0; i < c->filterCount; i++) {
        if (!navis_eq_filter_valid(&c->filters[i])) return false;
    }
    return true;
}

bool navis_eq_config_same(const NavisEqConfig *a, const NavisEqConfig *b) {
    if (a->enabled != b->enabled || a->autoHeadroom != b->autoHeadroom
        || a->preamp != b->preamp || a->filterCount != b->filterCount) return false;
    for (int i = 0; i < a->filterCount; i++) {
        const NavisEqFilter *x = &a->filters[i], *y = &b->filters[i];
        if (x->type != y->type || x->frequency != y->frequency || x->gain != y->gain
            || x->q != y->q || x->enabled != y->enabled) return false;
    }
    return true;
}

// MARK: Biquads

static NavisEqBiquad biquad(double b0, double b1, double b2, double a0, double a1, double a2) {
    NavisEqBiquad r = {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
    return r;
}

double navis_eq_biquad_db_at(const NavisEqBiquad *f, double frequency, double sampleRate) {
    double w = 2 * NAVIS_PI * frequency / sampleRate;
    double c1 = cos(w), c2 = cos(2 * w), s1 = sin(w), s2 = sin(2 * w);
    double nr = f->b0 + f->b1 * c1 + f->b2 * c2, ni = -f->b1 * s1 - f->b2 * s2;
    double dr = 1 + f->a1 * c1 + f->a2 * c2, di = -f->a1 * s1 - f->a2 * s2;
    double ratio = (nr * nr + ni * ni) / (dr * dr + di * di);
    return 10 * log10(ratio > 1e-30 ? ratio : 1e-30);
}

bool navis_eq_coefficients(const NavisEqFilter *f, double sampleRate, NavisEqBiquad *out) {
    bool shelfOrPeak = f->type == NAVIS_EQ_PEAKING || f->type == NAVIS_EQ_LOW_SHELF
        || f->type == NAVIS_EQ_HIGH_SHELF;
    if (!f->enabled || (shelfOrPeak && f->gain == 0)) {
        *out = biquad(1, 0, 0, 1, 0, 0);
        return true;
    }
    if (f->frequency >= sampleRate / 2) return false;
    double a = pow(10, f->gain / 40);
    double w = 2 * NAVIS_PI * f->frequency / sampleRate;
    double c = cos(w), alpha = sin(w) / (2 * f->q);
    double root = 2 * sqrt(a) * alpha;
    switch (f->type) {
        case NAVIS_EQ_PEAKING:
            *out = biquad(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a);
            return true;
        case NAVIS_EQ_LOW_SHELF:
            *out = biquad(a * ((a + 1) - (a - 1) * c + root),
                          2 * a * ((a - 1) - (a + 1) * c),
                          a * ((a + 1) - (a - 1) * c - root),
                          (a + 1) + (a - 1) * c + root,
                          -2 * ((a - 1) + (a + 1) * c),
                          (a + 1) + (a - 1) * c - root);
            return true;
        case NAVIS_EQ_HIGH_SHELF:
            *out = biquad(a * ((a + 1) + (a - 1) * c + root),
                          -2 * a * ((a - 1) + (a + 1) * c),
                          a * ((a + 1) + (a - 1) * c - root),
                          (a + 1) - (a - 1) * c + root,
                          2 * ((a - 1) - (a + 1) * c),
                          (a + 1) - (a - 1) * c - root);
            return true;
        case NAVIS_EQ_LOW_PASS:
            *out = biquad((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha);
            return true;
        case NAVIS_EQ_HIGH_PASS:
            *out = biquad((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha);
            return true;
        case NAVIS_EQ_NOTCH:
            *out = biquad(1, -2 * c, 1, 1 + alpha, -2 * c, 1 - alpha);
            return true;
    }
    return false;
}

static double response(const NavisEqBiquad *filters, int count, double hz, double sampleRate) {
    double gain = 0;
    for (int i = 0; i < count; i++) gain += navis_eq_biquad_db_at(&filters[i], hz, sampleRate);
    return gain;
}

double navis_eq_maximum_boost(const NavisEqBiquad *filters, int count, double sampleRate) {
    double upper = sampleRate / 2 * 0.9999;
    double lower = fmin(1, upper / 2), logLower = log(lower);
    double step = log(upper / lower) / 4096;
    double best = 0, bestLog = logLower;
    for (int i = 0; i <= 4096; i++) {
        double l = logLower + i * step;
        double value = response(filters, count, exp(l), sampleRate);
        if (value > best) { best = value; bestLog = l; }
    }
    double left = fmax(logLower, bestLog - step);
    double right = fmin(log(upper), bestLog + step);
    for (int i = 0; i < 24; i++) {
        double a = left + (right - left) / 3, b = right - (right - left) / 3;
        if (response(filters, count, exp(a), sampleRate) > response(filters, count, exp(b), sampleRate)) {
            right = b;
        } else {
            left = a;
        }
    }
    return fmax(best, response(filters, count, exp((left + right) / 2), sampleRate));
}

// MARK: Bank

NavisEqBank *navis_eq_bank_new(const NavisEqConfig *config, int sampleRate, int channels) {
    if (!navis_eq_config_valid(config) || sampleRate <= 0 || channels < 1 || channels > NAVIS_EQ_MAX_CHANNELS) {
        return NULL;
    }
    NavisEqBank *b = calloc(1, sizeof(NavisEqBank));
    if (!b) return NULL;
    b->sampleRate = sampleRate;
    b->channels = channels;
    bool supported = true;
    for (int i = 0; i < config->filterCount; i++) {
        if (config->filters[i].enabled && config->filters[i].frequency >= sampleRate / 2.0) supported = false;
    }
    b->enabled = config->enabled && supported;
    b->reason = config->enabled && !supported ? kUnsupportedRate : NULL;
    b->count = b->enabled ? config->filterCount : 0;
    for (int i = 0; i < b->count; i++) {
        if (!navis_eq_coefficients(&config->filters[i], sampleRate, &b->filters[i])) {
            free(b);
            return NULL;
        }
    }
    double peak = b->enabled ? navis_eq_maximum_boost(b->filters, b->count, sampleRate) + config->preamp : 0;
    b->headroom = b->enabled && config->autoHeadroom && peak > 0 ? -peak - 0.5 : 0;
    b->gain = b->enabled ? pow(10, (config->preamp + b->headroom) / 20) : 1;
    return b;
}

void navis_eq_bank_free(NavisEqBank *bank) { free(bank); }

double navis_eq_bank_process(NavisEqBank *bank, double value, int channel) {
    double dry = value;
    value *= bank->gain;
    double *z1 = bank->z1[channel], *z2 = bank->z2[channel];
    for (int i = 0; i < bank->count; i++) {
        const NavisEqBiquad *f = &bank->filters[i];
        double result = f->b0 * value + z1[i];
        z1[i] = f->b1 * value - f->a1 * result + z2[i];
        z2[i] = f->b2 * value - f->a2 * result;
        // Avoid denormal slowdowns during silence.
        if (fabs(z1[i]) < 1e-24) z1[i] = 0;
        if (fabs(z2[i]) < 1e-24) z2[i] = 0;
        value = result;
    }
    if (!isfinite(value)) {
        // A NaN/inf input would poison the history for good; drop it.
        memset(z1, 0, sizeof(double) * NAVIS_EQ_MAX_FILTERS);
        memset(z2, 0, sizeof(double) * NAVIS_EQ_MAX_FILTERS);
        return isfinite(dry) ? dry : 0;
    }
    return value;
}

// MARK: Stream

struct NavisEqStream {
    int sampleRate, channels, fadeFrames;
    _Atomic(NavisEqBank *) requested, applied, outgoing;
    _Atomic uint64_t calls, frames;
    _Atomic bool busy; // a process call is running
    _Atomic double inPower, outPower;
    // Audio thread only.
    int fadeRemaining;
    NavisEqBank *fadeBank;
    // Non-audio thread only: every bank not yet freed.
    NavisEqBank *banks;
};

NavisEqStream *navis_eq_stream_new(const NavisEqConfig *config, int sampleRate, int channels) {
    NavisEqBank *bank = navis_eq_bank_new(config, sampleRate, channels);
    if (!bank) return NULL;
    NavisEqStream *s = calloc(1, sizeof(NavisEqStream));
    if (!s) { navis_eq_bank_free(bank); return NULL; }
    s->sampleRate = sampleRate;
    s->channels = channels;
    s->fadeFrames = sampleRate / 50 > 1 ? sampleRate / 50 : 1;
    s->banks = bank;
    atomic_init(&s->requested, bank);
    atomic_init(&s->applied, bank);
    atomic_init(&s->outgoing, NULL);
    atomic_init(&s->calls, 0);
    atomic_init(&s->busy, false);
    atomic_init(&s->frames, 0);
    atomic_init(&s->inPower, 0.0);
    atomic_init(&s->outPower, 0.0);
    return s;
}

void navis_eq_stream_free(NavisEqStream *s) {
    if (!s) return;
    while (s->banks) {
        NavisEqBank *next = s->banks->next;
        navis_eq_bank_free(s->banks);
        s->banks = next;
    }
    free(s);
}

void navis_eq_stream_sweep(NavisEqStream *s) {
    uint64_t calls = atomic_load(&s->calls);
    bool busy = atomic_load(&s->busy);
    NavisEqBank *applied = atomic_load(&s->applied);
    NavisEqBank *outgoing = atomic_load(&s->outgoing);
    NavisEqBank **link = &s->banks;
    while (*link) {
        NavisEqBank *b = *link;
        // A bank leaves `requested` only here; a process call that started
        // before that may still hold it. It is safe once one call has finished
        // since, or when no call is running now (a call starting later reads
        // the new `requested`). After that the audio thread can only reach it
        // through applied/outgoing.
        if (b->retired && (calls > b->retiredAt || !busy) && b != applied && b != outgoing) {
            *link = b->next;
            navis_eq_bank_free(b);
        } else {
            link = &b->next;
        }
    }
}

bool navis_eq_stream_request(NavisEqStream *s, const NavisEqConfig *config) {
    NavisEqBank *bank = navis_eq_bank_new(config, s->sampleRate, s->channels);
    if (!bank) return false;
    bank->next = s->banks;
    s->banks = bank;
    NavisEqBank *old = atomic_exchange(&s->requested, bank);
    old->retired = true;
    old->retiredAt = atomic_load(&s->calls);
    navis_eq_stream_sweep(s);
    return true;
}

void navis_eq_stream_state(NavisEqStream *s, NavisEqStreamState *out) {
    // Banks are only freed by this (non-audio) thread, so the pointer stays valid.
    NavisEqBank *applied = atomic_load(&s->applied);
    out->enabled = applied->enabled;
    out->sampleRate = applied->sampleRate;
    out->headroomDb = applied->headroom;
    out->reason = applied->reason;
    out->pending = atomic_load(&s->requested) != applied;
    out->processedFrames = atomic_load(&s->frames);
    double in = atomic_load(&s->inPower), outP = atomic_load(&s->outPower);
    out->hasLevel = in > 1e-9;
    out->levelDeltaDb = out->hasLevel ? 10 * log10((outP > 1e-30 ? outP : 1e-30) / in) : 0;
}

int navis_eq_stream_channels(const NavisEqStream *s) { return s->channels; }
int navis_eq_stream_sample_rate(const NavisEqStream *s) { return s->sampleRate; }

int navis_eq_stream_bank_count(const NavisEqStream *s) {
    int n = 0;
    for (const NavisEqBank *b = s->banks; b; b = b->next) n++;
    return n;
}

void navis_eq_stream_reset_history(NavisEqStream *s) {
    // Only the audio thread touches the history of the applied and fading banks.
    NavisEqBank *banks[2] = {atomic_load(&s->applied), s->fadeBank};
    for (int i = 0; i < 2; i++) {
        if (!banks[i]) continue;
        memset(banks[i]->z1, 0, sizeof banks[i]->z1);
        memset(banks[i]->z2, 0, sizeof banks[i]->z2);
    }
}

void navis_eq_stream_process(NavisEqStream *s, float *const *ch, int channelCount, int frames) {
    if (frames <= 0 || channelCount != s->channels) return;
    atomic_store(&s->busy, true);
    NavisEqBank *requested = atomic_load(&s->requested);
    NavisEqBank *current = atomic_load(&s->applied);
    if (s->fadeRemaining == 0 && requested != current) {
        // Publish outgoing first: a sweep must never see the old bank in neither slot.
        atomic_store(&s->outgoing, current);
        atomic_store(&s->applied, requested);
        s->fadeBank = current;
        s->fadeRemaining = s->fadeFrames;
        current = requested;
    }
    double inSum = 0, outSum = 0;
    // The level window forgets linearly over about one second of frames and
    // restarts when a crossfade to a new bank ends, so the reading follows edits.
    bool discardWindow = false;
    if (s->fadeRemaining == 0 && !current->enabled) {
        for (int c = 0; c < channelCount; c++) {
            for (int i = 0; i < frames; i++) inSum += (double)ch[c][i] * ch[c][i];
        }
        outSum = inSum;
    } else {
        for (int i = 0; i < frames; i++) {
            double mix = s->fadeRemaining == 0 ? 1 : 1 - (double)s->fadeRemaining / s->fadeFrames;
            for (int c = 0; c < channelCount; c++) {
                double v = ch[c][i];
                double y = navis_eq_bank_process(current, v, c);
                if (s->fadeRemaining > 0) {
                    double old = navis_eq_bank_process(s->fadeBank, v, c);
                    y = old + (y - old) * mix;
                }
                float yf = (float)y;
                ch[c][i] = yf;
                inSum += v * v;
                outSum += (double)yf * yf;
            }
            if (s->fadeRemaining > 0 && --s->fadeRemaining == 0) {
                atomic_store(&s->outgoing, NULL);
                s->fadeBank = NULL;
                inSum = outSum = 0;
                discardWindow = true;
            }
        }
    }
    double keep = discardWindow ? 0 : 1 - (double)frames / s->sampleRate;
    if (keep < 0) keep = 0;
    atomic_store(&s->inPower, atomic_load(&s->inPower) * keep + inSum);
    atomic_store(&s->outPower, atomic_load(&s->outPower) * keep + outSum);
    atomic_fetch_add(&s->frames, (uint64_t)frames);
    atomic_fetch_add(&s->calls, 1); // tells sweep this call no longer holds any bank
    atomic_store(&s->busy, false);
}
