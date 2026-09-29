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

    public static void main(String[] args) {
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
        System.out.println("Equalizer DSP: response, headroom, PCM, channel isolation, bypass, and limits passed.");
    }
}
