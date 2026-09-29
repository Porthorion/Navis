package com.ryanheise.just_audio;

import java.util.Arrays;

/** App-owned cookbook biquads; this class has no Android dependencies. */
final class EqualizerDsp {
    static final class Filter {
        final String type;
        final double frequency, gain, q;
        final boolean enabled;

        Filter(String type, double frequency, double gain, double q, boolean enabled) {
            if (!Arrays.asList("peaking", "lowShelf", "highShelf", "lowPass", "highPass", "notch").contains(type)
                    || !Double.isFinite(frequency) || frequency < 20 || frequency > 20000
                    || !Double.isFinite(gain) || gain < -24 || gain > 24
                    || !Double.isFinite(q) || q < 0.1 || q > 20) {
                throw new IllegalArgumentException("EQ filter is outside supported limits");
            }
            this.type = type;
            this.frequency = frequency;
            this.gain = gain;
            this.q = q;
            this.enabled = enabled;
        }
    }

    static final class Configuration {
        final boolean enabled, autoHeadroom;
        final double preamp;
        final Filter[] filters;

        Configuration(boolean enabled, boolean autoHeadroom, double preamp, Filter[] filters) {
            if (!Double.isFinite(preamp) || preamp < -60 || preamp > 24 || filters.length > 32) {
                throw new IllegalArgumentException("EQ configuration is outside supported limits");
            }
            this.enabled = enabled;
            this.autoHeadroom = autoHeadroom;
            this.preamp = preamp;
            this.filters = filters.clone();
        }

        boolean sameAs(Configuration other) {
            if (enabled != other.enabled || autoHeadroom != other.autoHeadroom ||
                    preamp != other.preamp || filters.length != other.filters.length) return false;
            for (int i = 0; i < filters.length; i++) {
                Filter a = filters[i], b = other.filters[i];
                if (!a.type.equals(b.type) || a.frequency != b.frequency ||
                        a.gain != b.gain || a.q != b.q || a.enabled != b.enabled) return false;
            }
            return true;
        }

    }

    static final class Biquad {
        final double b0, b1, b2, a1, a2;

        Biquad(double b0, double b1, double b2, double a0, double a1, double a2) {
            this.b0 = b0 / a0;
            this.b1 = b1 / a0;
            this.b2 = b2 / a0;
            this.a1 = a1 / a0;
            this.a2 = a2 / a0;
        }

        double decibelsAt(double frequency, double sampleRate) {
            double w = 2 * Math.PI * frequency / sampleRate;
            double c1 = Math.cos(w), c2 = Math.cos(2 * w);
            double s1 = Math.sin(w), s2 = Math.sin(2 * w);
            double nr = b0 + b1 * c1 + b2 * c2, ni = -b1 * s1 - b2 * s2;
            double dr = 1 + a1 * c1 + a2 * c2, di = -a1 * s1 - a2 * s2;
            return 10 * Math.log10(Math.max(1e-30, (nr * nr + ni * ni) / (dr * dr + di * di)));
        }
    }

    static Biquad coefficients(Filter f, double sampleRate) {
        if (!f.enabled || ((f.type.equals("peaking") || f.type.endsWith("Shelf")) && f.gain == 0)) {
            return new Biquad(1, 0, 0, 1, 0, 0);
        }
        if (f.frequency >= sampleRate / 2) {
            throw new IllegalArgumentException("EQ frequency exceeds the audio sample rate");
        }
        double a = Math.pow(10, f.gain / 40);
        double w = 2 * Math.PI * f.frequency / sampleRate;
        double c = Math.cos(w), alpha = Math.sin(w) / (2 * f.q);
        double root = 2 * Math.sqrt(a) * alpha;
        switch (f.type) {
            case "peaking":
                return new Biquad(1 + alpha * a, -2 * c, 1 - alpha * a,
                        1 + alpha / a, -2 * c, 1 - alpha / a);
            case "lowShelf":
                return new Biquad(a * ((a + 1) - (a - 1) * c + root),
                        2 * a * ((a - 1) - (a + 1) * c),
                        a * ((a + 1) - (a - 1) * c - root),
                        (a + 1) + (a - 1) * c + root,
                        -2 * ((a - 1) + (a + 1) * c),
                        (a + 1) + (a - 1) * c - root);
            case "highShelf":
                return new Biquad(a * ((a + 1) + (a - 1) * c + root),
                        -2 * a * ((a - 1) + (a + 1) * c),
                        a * ((a + 1) + (a - 1) * c - root),
                        (a + 1) - (a - 1) * c + root,
                        2 * ((a - 1) - (a + 1) * c),
                        (a + 1) - (a - 1) * c - root);
            case "lowPass":
                return new Biquad((1 - c) / 2, 1 - c, (1 - c) / 2,
                        1 + alpha, -2 * c, 1 - alpha);
            case "highPass":
                return new Biquad((1 + c) / 2, -(1 + c), (1 + c) / 2,
                        1 + alpha, -2 * c, 1 - alpha);
            case "notch":
                return new Biquad(1, -2 * c, 1, 1 + alpha, -2 * c, 1 - alpha);
            default:
                throw new IllegalArgumentException("Unsupported EQ filter");
        }
    }

    static final class Bank {
        final Biquad[] filters;
        final double[][] z1, z2;
        final double gain, headroom;
        final int sampleRate, channels;
        final boolean enabled;
        final String reason;

        Bank(Configuration configuration, int sampleRate, int channels) {
            this.sampleRate = sampleRate;
            this.channels = channels;
            boolean supported = true;
            for (Filter f : configuration.filters) {
                if (f.enabled && f.frequency >= sampleRate / 2.0) supported = false;
            }
            this.enabled = configuration.enabled && supported;
            this.reason = configuration.enabled && !supported
                    ? "EQ frequency exceeds this audio format's sample rate." : null;
            filters = new Biquad[enabled ? configuration.filters.length : 0];
            for (int i = 0; i < filters.length; i++) {
                filters[i] = coefficients(configuration.filters[i], sampleRate);
            }
            double peak = enabled ? maximumBoost(filters, sampleRate) + configuration.preamp : 0;
            headroom = enabled && configuration.autoHeadroom && peak > 0 ? -peak - 0.5 : 0;
            gain = enabled ? Math.pow(10, (configuration.preamp + headroom) / 20) : 1;
            z1 = new double[channels][filters.length];
            z2 = new double[channels][filters.length];
        }

        double process(double value, int channel) {
            value *= gain;
            for (int i = 0; i < filters.length; i++) {
                Biquad f = filters[i];
                double result = f.b0 * value + z1[channel][i];
                z1[channel][i] = f.b1 * value - f.a1 * result + z2[channel][i];
                z2[channel][i] = f.b2 * value - f.a2 * result;
                // Avoid denormal slowdowns during silence.
                if (Math.abs(z1[channel][i]) < 1e-24) z1[channel][i] = 0;
                if (Math.abs(z2[channel][i]) < 1e-24) z2[channel][i] = 0;
                value = result;
            }
            return value;
        }
    }

    private static double response(Biquad[] filters, double hz, double sampleRate) {
        double gain = 0;
        for (Biquad filter : filters) gain += filter.decibelsAt(hz, sampleRate);
        return gain;
    }

    static double maximumBoost(Biquad[] filters, double sampleRate) {
        double upper = sampleRate / 2 * 0.9999;
        double lower = Math.min(1, upper / 2), logLower = Math.log(lower);
        double step = Math.log(upper / lower) / 4096;
        double best = 0, bestLog = logLower;
        for (int i = 0; i <= 4096; i++) {
            double log = logLower + i * step;
            double value = response(filters, Math.exp(log), sampleRate);
            if (value > best) { best = value; bestLog = log; }
        }
        double left = Math.max(logLower, bestLog - step);
        double right = Math.min(Math.log(upper), bestLog + step);
        for (int i = 0; i < 24; i++) {
            double a = left + (right - left) / 3, b = right - (right - left) / 3;
            if (response(filters, Math.exp(a), sampleRate) > response(filters, Math.exp(b), sampleRate)) {
                right = b;
            } else {
                left = a;
            }
        }
        return Math.max(best, response(filters, Math.exp((left + right) / 2), sampleRate));
    }
}
