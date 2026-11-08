// App-owned equalizer DSP: C port of android EqualizerDsp.java and the swap
// logic of NavisEqualizerProcessor.java (cookbook biquads, auto-headroom,
// per-channel history, banks built off the audio thread and swapped at block
// boundaries with a 20 ms crossfade). Pure C11, no platform dependencies, so
// the same file is unit-tested on any host (see darwin/test/).
#ifndef NAVIS_EQUALIZER_DSP_H
#define NAVIS_EQUALIZER_DSP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NAVIS_EQ_MAX_FILTERS 32
#define NAVIS_EQ_MAX_CHANNELS 8

typedef enum {
    NAVIS_EQ_PEAKING = 0,
    NAVIS_EQ_LOW_SHELF,
    NAVIS_EQ_HIGH_SHELF,
    NAVIS_EQ_LOW_PASS,
    NAVIS_EQ_HIGH_PASS,
    NAVIS_EQ_NOTCH,
} NavisEqFilterType;

typedef struct {
    int type; // NavisEqFilterType
    double frequency, gain, q;
    bool enabled;
} NavisEqFilter;

typedef struct {
    bool enabled, autoHeadroom;
    double preamp;
    int filterCount;
    NavisEqFilter filters[NAVIS_EQ_MAX_FILTERS];
} NavisEqConfig;

/// -1 for an unknown name.
int navis_eq_filter_type_from_name(const char *name);
/// Same limits as the Android implementation.
bool navis_eq_filter_valid(const NavisEqFilter *filter);
bool navis_eq_config_valid(const NavisEqConfig *config);
bool navis_eq_config_same(const NavisEqConfig *a, const NavisEqConfig *b);

typedef struct {
    double b0, b1, b2, a1, a2; // normalised by a0
} NavisEqBiquad;

/// False when an active filter's frequency is at or above Nyquist.
bool navis_eq_coefficients(const NavisEqFilter *filter, double sampleRate, NavisEqBiquad *out);
double navis_eq_biquad_db_at(const NavisEqBiquad *biquad, double frequency, double sampleRate);
double navis_eq_maximum_boost(const NavisEqBiquad *filters, int count, double sampleRate);

/// Immutable coefficients plus the per-channel filter history. Only one thread
/// may process through a bank at a time.
typedef struct NavisEqBank {
    int sampleRate, channels, count;
    bool enabled;
    const char *reason; // static string or NULL
    double gain, headroom;
    NavisEqBiquad filters[NAVIS_EQ_MAX_FILTERS];
    double z1[NAVIS_EQ_MAX_CHANNELS][NAVIS_EQ_MAX_FILTERS];
    double z2[NAVIS_EQ_MAX_CHANNELS][NAVIS_EQ_MAX_FILTERS];
    // Stream bookkeeping (main thread only).
    struct NavisEqBank *next;
    uint64_t retiredAt;
    bool retired;
} NavisEqBank;

/// NULL for an invalid configuration, rate or channel count (1...8).
NavisEqBank *navis_eq_bank_new(const NavisEqConfig *config, int sampleRate, int channels);
void navis_eq_bank_free(NavisEqBank *bank);
double navis_eq_bank_process(NavisEqBank *bank, double value, int channel);

/// One decoded audio stream (one prepare of the player's tap). Threading contract:
/// - request/sweep/state/free: one non-audio thread at a time (callers
///   serialise);
/// - process: the audio thread only, never concurrently with free.
/// process takes no locks, allocates nothing and does no log/pow/Objective-C.
typedef struct NavisEqStream NavisEqStream;

typedef struct {
    bool enabled, pending, hasLevel;
    int sampleRate;
    double headroomDb;
    const char *reason;
    uint64_t processedFrames;
    uint64_t resetCount; // filter histories dropped (seek, skip; a new stream starts empty)
    double levelDeltaDb; // 10 log10(out/in) over a recent window; valid if hasLevel
} NavisEqStreamState;

NavisEqStream *navis_eq_stream_new(const NavisEqConfig *config, int sampleRate, int channels);
void navis_eq_stream_free(NavisEqStream *stream);
/// Builds the new bank here (not on the audio thread); the audio thread swaps
/// at its next block boundary. Returns false for an invalid configuration.
bool navis_eq_stream_request(NavisEqStream *stream, const NavisEqConfig *config);
/// Frees retired banks the audio thread can no longer reach.
void navis_eq_stream_sweep(NavisEqStream *stream);
void navis_eq_stream_state(NavisEqStream *stream, NavisEqStreamState *out);
int navis_eq_stream_channels(const NavisEqStream *stream);
int navis_eq_stream_sample_rate(const NavisEqStream *stream);
/// Banks still allocated (applied, requested, fading and not-yet-freed retired
/// ones). Bounded regardless of how many edits arrive.
int navis_eq_stream_bank_count(const NavisEqStream *stream);
/// Audio thread only: forget the filter history, like Android's onFlush.
void navis_eq_stream_reset_history(NavisEqStream *stream);
/// Audio thread only, once per tap block before processing it. Forgets the
/// filter history (and counts a reset) when the block is the first after
/// prepare (`startOfStream`, latched until a block with audio arrives) or the
/// host flush generation changed since the last block with audio (seek, skip),
/// once per event even when both coincide. A stream that has not seen a block
/// with audio yet has an empty history: it consumes the event and counts nothing. A block with `frames` <= 0 (the tap
/// is called with an empty range while paused or seeking) never resets and
/// keeps the pending event for the next audio block. The source time range is
/// deliberately not an input: with one tap shared by the whole queue it
/// re-bases mid-song at every queue insert without any jump in the audio.
/// Returns true when it dropped a history.
bool navis_eq_stream_begin_block(NavisEqStream *stream, bool startOfStream, uint32_t flushGeneration, int frames);
/// In-place, non-interleaved float channels. A channel count that differs from
/// the stream's passes through untouched.
void navis_eq_stream_process(NavisEqStream *stream, float *const *channels, int channelCount, int frames);

#ifdef __cplusplus
}
#endif
#endif
