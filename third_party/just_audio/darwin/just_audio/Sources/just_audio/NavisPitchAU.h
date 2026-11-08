// AUNewTimePitch behind a NavisPitchRenderer (see NavisPitchStage.h). Built for
// iOS only (the macOS plugin never receives a tap) and for the Darwin host test
// (NAVIS_PITCH_AU_HOST_TEST), which links AudioToolbox itself.
#ifndef NAVIS_PITCH_AU_H
#define NAVIS_PITCH_AU_H

#include "NavisPitchStage.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NavisPitchAU NavisPitchAU;

/// Prepare time only: creates and initializes the unit for non-interleaved
/// float at `sampleRate`, rate 1, `maxFrames` per render. NULL on any failure.
NavisPitchAU *navis_pitch_au_new(double sampleRate, int channels, int maxFrames);
/// Unprepare only.
void navis_pitch_au_free(NavisPitchAU *au);
/// Input pulls whose size or buffer count differed from the block being rendered
/// (the missing part is zero-filled). Any thread; 0 in a healthy run.
uint64_t navis_pitch_au_pull_mismatches(const NavisPitchAU *au);
/// The renderer for navis_pitch_stage_new. Its callbacks are for the audio
/// thread (one AudioUnitRender per render, one input pull per render); the
/// stage also calls set_cents once from navis_pitch_stage_new, at prepare.
NavisPitchRenderer navis_pitch_au_renderer(NavisPitchAU *au);

#ifdef __cplusplus
}
#endif
#endif
