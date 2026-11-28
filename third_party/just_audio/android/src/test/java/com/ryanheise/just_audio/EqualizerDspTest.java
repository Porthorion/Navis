package com.ryanheise.just_audio;

/** Executable JVM response fixtures; assertions do not need an Android device. */
public final class EqualizerDspTest {
    private static void near(double actual, double expected, double tolerance, String context) {
        if (!Double.isFinite(actual) || Math.abs(actual - expected) > tolerance) {
            throw new AssertionError(context + ": expected " + expected + ", received " + actual);
        }
    }

    private static EqualizerDsp.Filter filter(String type, double frequency, double gain, double q) {
        return new EqualizerDsp.Filter(type, frequency, gain, q, true);
    }

    private static double measuredGain(EqualizerDsp.Bank bank, double frequency) {
        double inputPower = 0, outputPower = 0;
        for (int i = 0; i < 96000; i++) {
            double input = 0.02 * Math.sin(2 * Math.PI * frequency * i / 48000);
            double output = bank.process(input, 0);
            if (!Double.isFinite(output)) throw new AssertionError("Nonfinite audio output");
            if (i >= 48000) {
                inputPower += input * input;
                outputPower += output * output;
            }
            near(bank.process(0, 1), 0, 0, "Stereo channel isolation");
        }
        return 10 * Math.log10(outputPower / inputPower);
    }

    private static void boostRamp() {
        int frames = 960; // 20 ms at 48 kHz
        near(EqualizerDsp.GainRamp.linear(0), 1, 0, "0 dB boost is the identity");
        near(EqualizerDsp.GainRamp.linear(6.0206), 2, 0.0001, "+6 dB doubles the amplitude");
        near(EqualizerDsp.GainRamp.linear(-9), 0.35481, 0.00001, "A cut of 9 dB scales by 0.355");
        near(EqualizerDsp.GainRamp.linear(-6.0206), 0.5, 0.0001, "-6 dB halves the amplitude");
        near(EqualizerDsp.GainRamp.linear(30), EqualizerDsp.GainRamp.linear(12), 0, "Boost is capped at 12 dB");
        near(EqualizerDsp.GainRamp.linear(Double.NaN), 1, 0, "NaN is no boost");
        EqualizerDsp.GainRamp ramp = new EqualizerDsp.GainRamp(frames);
        near(ramp.next(), 1, 0, "A fresh ramp is the identity");
        double target = EqualizerDsp.GainRamp.linear(10);
        ramp.setTarget(10);
        double previous = 1;
        for (int i = 1; i <= frames; i++) {
            double gain = ramp.next();
            near(gain, 1 + (target - 1) * i / frames, 1e-9, "Linear gain ramp at frame " + i);
            if (gain <= previous) throw new AssertionError("Ramp is not rising at frame " + i);
            previous = gain;
        }
        near(previous, target, 0, "Ramp reaches the target in exactly fadeFrames");
        near(ramp.next(), target, 0, "Ramp holds the target");
        near(ramp.db(), 10, 1e-9, "Applied dB");
        ramp.setTarget(10);
        near(ramp.next(), target, 0, "Same target restarts nothing");
        ramp.setTarget(0);
        near(ramp.next(), target + (1 - target) / frames, 1e-9, "Lowering ramps down");
        ramp.snap(-6.0206);
        ramp.setTarget(-12.0412);
        for (int i = 0; i < frames; i++) ramp.next();
        near(ramp.next(), 0.25, 0.0001, "A cut ramps down to its target");
        near(ramp.db(), -12.0412, 0.001, "Applied dB of a cut");
        ramp.snap(4);
        near(ramp.next(), EqualizerDsp.GainRamp.linear(4), 0, "Snap jumps without a ramp");
        ramp.setTarget(8);
        for (int i = 0; i < frames / 2; i++) ramp.next();
        double middle = ramp.next();
        ramp.setTarget(2);
        double after = ramp.next();
        if (!(after < middle)) throw new AssertionError("A new target ramps from the current gain");
        for (int i = 0; i < frames; i++) ramp.next();
        near(ramp.next(), EqualizerDsp.GainRamp.linear(2), 0, "Retargeted ramp ends on the new target");
    }

    // #846 limiter vectors: the same blocks, signals and assertions as navis_boost_test.c.
    private static final float CEIL = EqualizerDsp.Limiter.CEILING, TOL = 1e-6f, TEN_DB = 2.2387211f;

    private static void check(boolean ok, String context) {
        if (!ok) throw new AssertionError(context);
    }

    /** Interleaved stereo sine of [amp] at 440 Hz continuing from frame [from]; right is half the left. */
    private static void sine(float[] x, int frames, long from, float amp, int rate) {
        for (int i = 0; i < frames; i++) {
            x[2 * i] = amp * (float) Math.sin(6.2831853f * 440.0f * (float) (from + i) / rate);
            x[2 * i + 1] = 0.5f * x[2 * i];
        }
    }

    private static void limiterHotSineStaysUnderCeiling() {
        for (int n : new int[]{960, 1024, 4096}) {
            EqualizerDsp.Limiter lim = new EqualizerDsp.Limiter(44100, n);
            float[] x = new float[2 * n], in = new float[2 * n];
            long limited = 0, pos = 0;
            for (int b = 0; b < 40; b++, pos += n) {
                sine(x, n, pos, 0.95f * TEN_DB, 44100);
                System.arraycopy(x, 0, in, 0, x.length);
                limited += lim.process(x, 2, n, true);
                for (int i = 0; i < x.length; i++) {
                    check(Math.abs(x[i]) <= CEIL + TOL, "every output sample is under the ceiling");
                    check(Math.abs(x[i]) <= Math.abs(in[i]) * (1 + TOL), "the limiter never raises a sample");
                }
                check(lim.gain() <= 1 && lim.gain() > 0, "gain stays in (0, 1]");
            }
            check(limited > 0, "a sine over the ceiling is limited");
        }
    }

    private static void limiterIsBitExactUnderTheCeiling() {
        EqualizerDsp.Limiter lim = new EqualizerDsp.Limiter(44100, 1024);
        float[] x = new float[2048], ref;
        for (int i = 0; i < 1024; i++) {
            x[2 * i] = 0.8f * (float) Math.sin(0.05f * i);
            x[2 * i + 1] = -0.3f * (float) Math.cos(0.11f * i);
        }
        ref = x.clone();
        check(lim.process(x, 2, 1024, true) == 0, "nothing limited");
        check(java.util.Arrays.equals(x, ref), "bit-identical passthrough");
        check(lim.gain() == 1f, "gain untouched");
        x[10] = ref[10] = 3f;
        check(lim.process(x, 2, 1024, false) == 0 && x[10] == 3f, "not armed: inert");
    }

    // Closed form: mono 0.5 with one 2.0 at the last frame of 100; g[i] = min(1, need + (99-i)/attackFrames).
    private static void limiterAttackGolden() {
        EqualizerDsp.Limiter lim = new EqualizerDsp.Limiter(44100, 100);
        float[] d = new float[100];
        java.util.Arrays.fill(d, 0.5f);
        d[99] = 2f;
        long limited = lim.process(d, 1, 100, true);
        float need = CEIL / 2f;
        long expect = 0;
        for (int i = 0; i < 100; i++) {
            float g = Math.min(1f, need + (float) (99 - i) / 88); // 2 ms at 44.1 kHz
            if (g < 1) expect++;
            near(d[i], (i == 99 ? 2f : 0.5f) * g, 2e-5, "attack ramp matches the closed form");
        }
        check(limited == expect && limited == 49, "limited frames are those with g < 1");
        near(lim.gain(), need, 1e-6, "the state carries the final gain");
    }

    private static void limiterPeakAtBlockStart() {
        EqualizerDsp.Limiter lim = new EqualizerDsp.Limiter(44100, 960);
        float[] d = new float[960];
        java.util.Arrays.fill(d, 0.2f);
        d[0] = 3f;
        lim.process(d, 1, 960, true);
        check(Math.abs(d[0]) <= CEIL + TOL, "a peak on the first sample is still under the ceiling");
        check(d[1] <= 0.2f + TOL && d[1] > 0, "and its neighbours are not amplified");
    }

    private static void limiterRecovers() {
        EqualizerDsp.Limiter lim = new EqualizerDsp.Limiter(44100, 1024);
        float[] d = new float[1024];
        java.util.Arrays.fill(d, 4f);
        lim.process(d, 1, 1024, true);
        check(lim.gain() < 0.3f, "deep reduction first");
        for (int b = 0; b < 22; b++) { // 0.51 s, boost gone but the limiter keeps running
            java.util.Arrays.fill(d, 0.1f);
            lim.process(d, 1, 1024, false);
        }
        check(lim.gain() > 0.99f && lim.gain() <= 1f, "gain is back above 0.99 within 0.5 s");
        for (int b = 0; b < 100; b++) lim.process(d, 1, 1024, false);
        check(lim.gain() == 1f, "and snaps back to inert unity");
    }

    private static void limiterChannelsAreLinked() {
        EqualizerDsp.Limiter lim = new EqualizerDsp.Limiter(44100, 4096);
        float[] x = new float[8192];
        sine(x, 4096, 0, 2.4f, 44100);
        float[] in = x.clone();
        lim.process(x, 2, 4096, true);
        for (int i = 0; i < 4096; i++) {
            float g = in[2 * i] != 0 ? x[2 * i] / in[2 * i] : 1;
            near(x[2 * i + 1], 0.5f * in[2 * i] * g, 1e-6, "both channels get the same gain");
        }
    }

    private static void limiterNanAndInfDoNotPoison() {
        EqualizerDsp.Limiter lim = new EqualizerDsp.Limiter(44100, 512);
        float[] d = new float[512];
        java.util.Arrays.fill(d, 2f);
        d[10] = Float.NaN;
        d[20] = Float.POSITIVE_INFINITY;
        lim.process(d, 1, 512, true);
        check(Float.isFinite(lim.gain()) && lim.gain() > 0 && lim.gain() <= 1f, "gain stays finite and in (0, 1]");
        for (int b = 0; b < 3; b++) {
            java.util.Arrays.fill(d, 2f);
            lim.process(d, 1, 512, true);
            for (float v : d) check(Float.isFinite(v) && Math.abs(v) <= CEIL + TOL, "later blocks are clean");
        }
    }

    private static void limiterReset() {
        EqualizerDsp.Limiter lim = new EqualizerDsp.Limiter(44100, 512);
        float[] d = new float[512];
        java.util.Arrays.fill(d, 4f);
        lim.process(d, 1, 512, true);
        check(lim.gain() < 1f, "reduced");
        lim.reset();
        check(lim.gain() == 1f, "reset puts the gain back to unity");
        java.util.Arrays.fill(d, 0.1f);
        check(lim.process(d, 1, 512, false) == 0 && d[0] == 0.1f, "and the next block is untouched");
    }

    private static void limiterChunksLongBlocks() {
        EqualizerDsp.Limiter lim = new EqualizerDsp.Limiter(44100, 256);
        float[] x = new float[8192];
        sine(x, 4096, 0, 2f, 44100);
        lim.process(x, 2, 4096, true);
        for (float v : x) check(Math.abs(v) <= CEIL + TOL, "chunked output is under the ceiling");
    }

    private static void limiterGainNeverAboveOne() {
        EqualizerDsp.Limiter lim = new EqualizerDsp.Limiter(48000, 960);
        float[] x = new float[1920];
        int seed = 1;
        for (int b = 0; b < 200; b++) {
            float amp = (b % 7) * 0.6f;
            for (int i = 0; i < 960; i++) {
                seed = seed * 1664525 + 1013904223;
                x[2 * i] = amp * ((float) (seed >>> 8) / 8388608.0f - 1.0f);
                x[2 * i + 1] = -x[2 * i];
            }
            lim.process(x, 2, 960, true);
            check(lim.gain() <= 1f && lim.gain() > 0f, "gain never exceeds 1");
            for (int i = 0; i < 960; i++) check(Math.abs(x[2 * i]) <= CEIL + TOL, "random bursts stay under the ceiling");
        }
    }

    public static void main(String[] args) {
        boostRamp();
        limiterHotSineStaysUnderCeiling();
        limiterIsBitExactUnderTheCeiling();
        limiterAttackGolden();
        limiterPeakAtBlockStart();
        limiterRecovers();
        limiterChannelsAreLinked();
        limiterNanAndInfDoNotPoison();
        limiterReset();
        limiterChunksLongBlocks();
        limiterGainNeverAboveOne();
        for (double sampleRate : new double[]{44100, 48000, 96000}) {
            for (double q : new double[]{0.1, 0.7, 1.41, 6, 20}) {
                EqualizerDsp.Biquad peak = EqualizerDsp.coefficients(filter("peaking", 1234.5, 9.3, q), sampleRate);
                near(peak.decibelsAt(1234.5, sampleRate), 9.3, 0.00001, "Peaking center/Q");
            }
            EqualizerDsp.Biquad low = EqualizerDsp.coefficients(filter("lowShelf", 105, 6, 0.7), sampleRate);
            near(low.decibelsAt(105, sampleRate), 3, 0.00001, "AutoEQ low shelf/Q");
            EqualizerDsp.Biquad high = EqualizerDsp.coefficients(filter("highShelf", 10000, -6, 0.7), sampleRate);
            near(high.decibelsAt(10000, sampleRate), -3, 0.00001, "AutoEQ high shelf/Q");
            for (String type : new String[]{"lowPass", "highPass"}) {
                EqualizerDsp.Biquad pass = EqualizerDsp.coefficients(filter(type, 1000, 0, Math.sqrt(0.5)), sampleRate);
                near(pass.decibelsAt(1000, sampleRate), -3.0102999566, 0.00001, "Butterworth cutoff");
            }
        }
        EqualizerDsp.Filter[] overlapping = {filter("peaking", 1000, 6, 1), filter("peaking", 1000, 6, 1)};
        EqualizerDsp.Bank protectedBank = new EqualizerDsp.Bank(
                new EqualizerDsp.Configuration(true, true, 0, overlapping), 48000, 2);
        near(protectedBank.headroom, -12.5, 0.001, "Combined boost headroom");
        near(measuredGain(protectedBank, 1000), -0.5, 0.01, "Measured PCM response with headroom");
        EqualizerDsp.Bank unrestricted = new EqualizerDsp.Bank(
                new EqualizerDsp.Configuration(true, false, -3, overlapping), 48000, 2);
        near(measuredGain(unrestricted, 1000), 9, 0.01, "Measured PCM preamp/curve");
        EqualizerDsp.Bank bypass = new EqualizerDsp.Bank(
                new EqualizerDsp.Configuration(false, true, 24, overlapping), 48000, 2);
        near(measuredGain(bypass, 1000), 0, 0.000001, "Bypass is unity");
        EqualizerDsp.Bank lowRate = new EqualizerDsp.Bank(new EqualizerDsp.Configuration(true, true, 0,
                new EqualizerDsp.Filter[]{filter("peaking", 16000, 6, 1)}), 22050, 2);
        if (lowRate.enabled || lowRate.reason == null) throw new AssertionError("Low-rate profile was partially applied");
        near(lowRate.process(0.12345, 0), 0.12345, 0, "Unsupported complete-profile bypass");
        boolean invalid = false;
        try { filter("peaking", 1000, 25, 1); } catch (IllegalArgumentException expected) { invalid = true; }
        if (!invalid) throw new AssertionError("Invalid filter accepted");
        System.out.println("Equalizer DSP: response, headroom, PCM, channel isolation, bypass, boost ramp, limiter, and limits passed.");
    }
}
