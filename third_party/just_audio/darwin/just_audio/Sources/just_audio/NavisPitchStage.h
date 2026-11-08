// Independent pitch for the iOS tap (I21): the state machine around a renderer
// (an AUNewTimePitch on device, see NavisPitchAU.c; a fake in the host test).
// It decides when the renderer runs and what the tap outputs: bit-exact bypass
// at pitch 0, wet from the first frame after a reset, a 20 ms dry/wet ramp for
// a user switch on or off mid-play. Pure C11, no platform dependencies, so the
// same file is unit-tested on any host (see darwin/test/).
#ifndef NAVIS_PITCH_STAGE_H
#define NAVIS_PITCH_STAGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NAVIS_PITCH_MAX_CHANNELS 8
/// AUNewTimePitch range: +-2 octaves.
#define NAVIS_PITCH_MAX_CENTS 2400

/// The pitch shifter behind the stage. All callbacks run on the audio thread
/// (render, reset, set_cents) except none: the stage never calls them
/// elsewhere. `in` is the stage's own scratch copy of the block.
typedef struct {
    void *user;
    /// Writes `frames` frames to `out` for the `frames` frames of `in`; 0 on success.
    int (*render)(void *user, const float *const *in, float *const *out, int channels, int frames);
    /// Drops everything the renderer buffered.
    void (*reset)(void *user);
    void (*set_cents)(void *user, float cents);
    /// Frames the renderer delays its input by.
    int latencyFrames;
} NavisPitchRenderer;

typedef struct {
    int32_t cents;          // requested
    bool active;            // not bypassed (includes priming and the ramps)
    int latencyFrames;
    uint64_t resetCount;    // note_reset events consumed (a new stage starts at 0)
    uint64_t renderErrors;
    float inputHz, outputHz; // zero-crossing estimates over the last second of audio; 0 before one
} NavisPitchState;

typedef struct NavisPitchStage NavisPitchStage;

/// Prepare time only (allocates). NULL for an invalid argument. The stage does
/// not own the renderer's `user`. A stage created with non-zero cents is wet from
/// its first frame (its renderer is fresh, like after a reset).
NavisPitchStage *navis_pitch_stage_new(const NavisPitchRenderer *renderer, int channels, int maxFrames,
                                       double sampleRate, float initialCents);
/// Unprepare only; never touches the renderer.
void navis_pitch_stage_free(NavisPitchStage *stage);
/// Any thread. Rounded and clamped to +-NAVIS_PITCH_MAX_CENTS; applied at the
/// next block.
void navis_pitch_stage_request(NavisPitchStage *stage, float cents);
/// Audio thread, right after navis_eq_stream_begin_block with its return value
/// (and before any layout early-return). Latched until the next block of audio.
void navis_pitch_stage_note_reset(NavisPitchStage *stage);
/// Audio thread, in place, non-interleaved float, blocks with audio only. A
/// channel count that differs from the stage's passes through; blocks longer
/// than maxFrames are processed in chunks. No allocation, locks or log/pow.
void navis_pitch_stage_process(NavisPitchStage *stage, float *const *channels, int channelCount, int frames);
/// Any thread.
void navis_pitch_stage_state(NavisPitchStage *stage, NavisPitchState *out);

#ifdef __cplusplus
}
#endif
#endif
