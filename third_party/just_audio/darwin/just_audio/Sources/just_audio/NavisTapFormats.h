// One tap stream per audio format (I25). AVQueuePlayer runs one audio pipeline
// per run of queue items with the same source format; every pipeline prepares
// and unprepares the player's one shared MTAudioProcessingTap, on non-render
// threads, and calls process for its own audio on a render thread. This set
// keeps an equalizer stream and a pitch stage per (rate, channels) key, so each
// block runs at its own format. Slots live until the set is freed (a pause, seek
// or song change never rebuilds one); only a 17th format, with no pipeline live,
// starts over. Pure C11 + pthread, so the same file is unit-tested on any host
// (see darwin/test/navis_tap_formats_test.c); the MediaToolbox glue is in
// NavisEqualizer.m.
//
// Threading contract (from MTAudioProcessingTap.h): process runs only between
// prepare returning and unprepare being called, for the pipeline that prepared.
// - process: render threads. Takes no locks, allocates nothing and does no
//   log/pow/Objective-C. Several render threads may overlap (two pipelines at
//   a format change); a slot used by two at once passes the later block dry.
// - prepare, unprepare, configure, set_cents, state: any non-render thread.
// - free: the tap's finalize, nothing else running.
#ifndef NAVIS_TAP_FORMATS_H
#define NAVIS_TAP_FORMATS_H

#include <stdbool.h>
#include <stdint.h>

#include "NavisEqualizerDsp.h"
#include "NavisPitchStage.h"

#ifdef __cplusplus
extern "C" {
#endif

/// The AudioUnit behind a pitch renderer: NavisPitchAU on iOS, a fake in tests.
typedef struct {
    /// Prepare time. NULL on failure (the slot then has no pitch). Fills `out`.
    void *(*create)(double rate, int channels, int maxFrames, NavisPitchRenderer *out);
    void (*destroy)(void *au);
    /// Input pulls that did not match the block; any thread.
    uint64_t (*mismatches)(const void *au);
} NavisPitchFactory;

/// Formats held at once. Realistic queues use about 6 rates x 2 channel counts.
#define NAVIS_TAP_MAX_FORMATS 16

typedef struct NavisTapFormats NavisTapFormats;

typedef struct {
    int sampleRate, channels;
    uint64_t processedFrames, resetCount, pitchResetCount;
    bool hasLevel;
    double levelDeltaDb;
} NavisTapFormatInfo;

typedef struct {
    int slotCount;            // formats held
    int live;                 // pipelines prepared and not yet unprepared
    uint64_t prepareCount;    // pipelines prepared
    /// Audio frames no slot was picked for (a rate or channel count nobody
    /// prepared), passed dry. 0 in a healthy run.
    uint64_t unmatchedFrames;
    /// Blocks passed dry because their slot was in use by another render thread.
    uint64_t overlapBlocks;
    /// Sums over the live slots plus what freed slots had reached.
    uint64_t processedFrames, resetCount, pitchResetCount, pitchPullMismatches;
    /// The slot that processed the last audio block (before any: the latest
    /// prepared one). Valid when `hasStream` / `hasPitch`.
    bool hasStream, hasPitch;
    NavisEqStreamState stream;
    NavisPitchState pitch;
    /// Why the latest prepare has no stream or no pitch; static strings or NULL.
    /// Set only while it matters: nothing has been processed yet, or the last
    /// audio block went through dry.
    const char *formatReason, *pitchReason;
    NavisTapFormatInfo formats[NAVIS_TAP_MAX_FORMATS]; // [0, slotCount)
} NavisTapFormatsState;

/// `config` and `cents` seed every slot made later.
NavisTapFormats *navis_tap_formats_new(const NavisEqConfig *config, int32_t cents, NavisPitchFactory factory);
void navis_tap_formats_free(NavisTapFormats *t);
/// Counts a pipeline as live. True when the format has a slot (made here when
/// new; reused untouched when held), so this pipeline's blocks are processed.
/// False (reason set) for a format that is not planar float, a failed
/// build, or a new format while all slots are taken and another pipeline is
/// live: that pipeline plays unchanged. A new format with all slots taken and
/// no other pipeline live frees every slot first.
bool navis_tap_formats_prepare(NavisTapFormats *t, double rate, int channels, int maxFrames, bool planarFloat);
/// A pipeline ended. Frees nothing. False when no prepare was left to match
/// (the count stays 0).
bool navis_tap_formats_unprepare(NavisTapFormats *t);
/// Realtime. One tap block of non-interleaved float `channels`, in place.
/// `durationValue`/`timescale` are the source range duration of the block
/// (CMTime), 0 when the range is not valid: they give the block's rate,
/// frames * timescale / value, to within the CMTime rounding. With one slot
/// that slot is used whenever its channel count matches. With several, the slot
/// of that channel count whose rate is nearest to the block's is used, within 4
/// % or inside the rounding interval; a block with an invalid range (not audio
/// yet) or no such slot passes dry.
void navis_tap_formats_process(NavisTapFormats *t, bool startOfStream, uint32_t flushGeneration,
                               int64_t durationValue, int32_t timescale, float *const *channels,
                               int count, int frames);
/// Builds the new banks here and hands them to every slot.
void navis_tap_formats_configure(NavisTapFormats *t, const NavisEqConfig *config);
/// Cents already clamped to +-NAVIS_PITCH_MAX_CENTS by the caller.
void navis_tap_formats_set_cents(NavisTapFormats *t, int32_t cents);
void navis_tap_formats_state(NavisTapFormats *t, NavisTapFormatsState *out);

#ifdef __cplusplus
}
#endif
#endif
