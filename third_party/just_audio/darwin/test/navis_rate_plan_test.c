// Host-side tests for NavisRatePlan.c (iOS Pitch Lock as one Varispeed stage, #528):
// the rate plan, the scaled EQ config and where a scaled band is heard.
// Run by tool/equalizer_native_test.sh under ASan/UBSan.
#include "../just_audio/Sources/just_audio/NavisRatePlan.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void check(bool ok, const char *context) {
    if (!ok) {
        fprintf(stderr, "FAIL %s\n", context);
        exit(1);
    }
}

static void near(double actual, double expected, double tolerance, const char *context) {
    if (!isfinite(actual) || fabs(actual - expected) > tolerance) {
        fprintf(stderr, "FAIL %s: expected %g, received %g\n", context, expected, actual);
        exit(1);
    }
}

static void expectPlan(double speed, double pitch, NavisRateAlgorithm algorithm, double cents, double scale, const char *context) {
    NavisRatePlan plan = navis_rate_plan(speed, pitch);
    check(plan.algorithm == algorithm, context);
    near(plan.tapCents, cents, 0.01, context);
    near(plan.eqFrequencyScale, scale, 1e-6, context);
}

static void testPlan(void) {
    expectPlan(1.25, 1.25, NAVIS_RATE_VARISPEED, 0, 1 / 1.25, "locked 1.25");
    expectPlan(0.8, 0.8, NAVIS_RATE_VARISPEED, 0, 1 / 0.8, "locked 0.8");
    expectPlan((double)(float)1.1, 1.1, NAVIS_RATE_VARISPEED, 0, 1 / 1.1, "locked float vs double");
    expectPlan(1, 1, NAVIS_RATE_TIME_DOMAIN, 0, 1, "1x");
    expectPlan(1.25, 1, NAVIS_RATE_TIME_DOMAIN, 0, 1, "speed only");
    expectPlan(1, 1.25, NAVIS_RATE_TIME_DOMAIN, 1200 * log2(1.25), 1, "pitch only");
    expectPlan(1.25, 1.12, NAVIS_RATE_TIME_DOMAIN, 1200 * log2(1.12), 1, "both, unlocked");
    expectPlan(NAN, 1, NAVIS_RATE_TIME_DOMAIN, 0, 1, "NaN speed");
    expectPlan(1, NAN, NAVIS_RATE_TIME_DOMAIN, 0, 1, "NaN pitch");
    expectPlan(INFINITY, INFINITY, NAVIS_RATE_TIME_DOMAIN, 0, 1, "infinite");
    expectPlan(0, 0, NAVIS_RATE_TIME_DOMAIN, 0, 1, "zero");
    expectPlan(-1.25, -1.25, NAVIS_RATE_TIME_DOMAIN, 0, 1, "negative");
}

static NavisEqConfig config(void) {
    NavisEqConfig c = {.enabled = true, .autoHeadroom = true, .preamp = -3, .filterCount = 3};
    c.filters[0] = (NavisEqFilter){NAVIS_EQ_PEAKING, 1000, 6, 1.5, true};
    c.filters[1] = (NavisEqFilter){NAVIS_EQ_LOW_SHELF, 31, -4, 0.7, true};
    c.filters[2] = (NavisEqFilter){NAVIS_EQ_HIGH_SHELF, 16000, 3, 0.7, true};
    return c;
}

static void testScaled(void) {
    NavisEqConfig in = config(), out;
    navis_eq_config_scaled(&in, 0.8, &out);
    near(out.filters[0].frequency, 800, 1e-9, "1000 Hz x 0.8");
    check(out.filters[0].enabled && out.filters[0].gain == 6 && out.filters[0].q == 1.5
          && out.filters[0].type == NAVIS_EQ_PEAKING, "other filter fields unchanged");
    check(out.enabled && out.autoHeadroom && out.preamp == -3 && out.filterCount == 3, "config fields unchanged");
    check(navis_eq_config_valid(&out), "scaled config is valid");

    navis_eq_config_scaled(&in, 0.5, &out);
    near(out.filters[1].frequency, 20, 1e-9, "31 Hz x 0.5 clamps to 20");
    check(out.filters[1].enabled, "clamped band stays enabled");
    near(out.filters[2].frequency, 8000, 1e-9, "16 kHz x 0.5");

    navis_eq_config_scaled(&in, 2, &out);
    check(!out.filters[2].enabled, "16 kHz x 2 is disabled");
    check(out.filters[0].enabled, "other bands stay enabled");
    check(navis_eq_config_valid(&out), "disabled band keeps a valid frequency");
    NavisEqBank *bank = navis_eq_bank_new(&out, 44100, 2);
    check(bank && bank->enabled, "a disabled band does not turn the whole EQ off");
    navis_eq_bank_free(bank);

    navis_eq_config_scaled(&in, 1, &out);
    check(navis_eq_config_same(&in, &out), "scale 1 is an exact copy");
}

// A 1 kHz +12 dB peak scaled by 1/1.25 peaks at 800 Hz: heard at 1 kHz after a 1.25x resample.
static void testPlacement(void) {
    NavisEqConfig in = {.enabled = true, .filterCount = 1}, out;
    in.filters[0] = (NavisEqFilter){NAVIS_EQ_PEAKING, 1000, 12, 2, true};
    NavisRatePlan plan = navis_rate_plan(1.25, 1.25);
    navis_eq_config_scaled(&in, plan.eqFrequencyScale, &out);
    NavisEqBiquad biquad;
    check(navis_eq_coefficients(&out.filters[0], 44100, &biquad), "coefficients");
    double bestHz = 0, bestDb = -1e9;
    for (double hz = 100; hz <= 5000; hz += 1) {
        double db = navis_eq_biquad_db_at(&biquad, hz, 44100);
        if (db > bestDb) { bestDb = db; bestHz = hz; }
    }
    near(bestHz, 800, 2, "peak at 800 Hz");
    near(bestDb, 12, 0.1, "peak gain");
    near(bestHz * 1.25, 1000, 3, "heard at 1 kHz after the resample");
}

int main(void) {
    testPlan();
    testScaled();
    testPlacement();
    printf("navis_rate_plan_test: all passed\n");
    return 0;
}
