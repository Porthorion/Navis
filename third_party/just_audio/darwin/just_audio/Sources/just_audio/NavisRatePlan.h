// Pitch Lock on iOS (#528): decides how speed and pitch are rendered. A locked
// pair (pitch == speed) is one resample in AVPlayer (Varispeed) with the tap's
// pitch at 0 and the EQ bands moved to f / speed, so they are heard where the
// user set them (the tap EQ runs before the rate). Everything else keeps
// AVPlayer's TimeDomain stretch and the tap's independent pitch. Pure C11, no
// platform dependencies, unit-tested on any host (darwin/test/navis_rate_plan_test.c).
#ifndef NAVIS_RATE_PLAN_H
#define NAVIS_RATE_PLAN_H

#include "NavisEqualizerDsp.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { NAVIS_RATE_TIME_DOMAIN = 0, NAVIS_RATE_VARISPEED = 1 } NavisRateAlgorithm;

typedef struct {
    NavisRateAlgorithm algorithm;
    float tapCents;           // pitch for the tap
    double eqFrequencyScale;  // multiplies every EQ filter frequency
} NavisRatePlan;

/// Invalid input (non-finite, <= 0) gives {TIME_DOMAIN, 0, 1}.
NavisRatePlan navis_rate_plan(double speed, double pitch);
/// Copies `in` with each filter frequency x `scale`. A result above 20000 Hz
/// disables that filter (no source content maps there; its frequency stays at
/// 20000 so the config is valid); below 20 Hz it is clamped to 20. Scale 1 is
/// an exact copy.
void navis_eq_config_scaled(const NavisEqConfig *in, double scale, NavisEqConfig *out);

#ifdef __cplusplus
}
#endif
#endif
