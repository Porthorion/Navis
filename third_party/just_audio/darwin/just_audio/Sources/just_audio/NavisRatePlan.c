#include "NavisRatePlan.h"

#include <math.h>

NavisRatePlan navis_rate_plan(double speed, double pitch) {
    NavisRatePlan plan = {NAVIS_RATE_TIME_DOMAIN, 0, 1};
    if (!isfinite(speed) || !isfinite(pitch) || speed <= 0 || pitch <= 0) return plan;
    // Speed arrives as a float, pitch as a double: 1.1f and 1.1 differ by ~2e-8.
    bool locked = fabs(speed - pitch) <= 1e-4 * pitch;
    if (locked && fabs(speed - 1) > 1e-4) {
        plan.algorithm = NAVIS_RATE_VARISPEED;
        plan.eqFrequencyScale = 1 / speed;
    } else if (!locked) {
        plan.tapCents = (float)(1200 * log2(pitch));
    }
    return plan;
}

void navis_eq_config_scaled(const NavisEqConfig *in, double scale, NavisEqConfig *out) {
    *out = *in;
    if (scale == 1) return;
    for (int i = 0; i < out->filterCount; i++) {
        NavisEqFilter *f = &out->filters[i];
        double hz = f->frequency * scale;
        if (hz > 20000) {
            f->frequency = 20000;
            f->enabled = false;
        } else {
            f->frequency = hz < 20 ? 20 : hz;
        }
    }
}
