package com.ryanheise.just_audio;

import java.util.Collections;
import java.util.List;
import java.util.Map;

/** Executable JVM fixtures using the same harness pattern as EqualizerDspTest. */
public final class ProgressiveLoadRetryTest {
    private static void check(boolean expected, String scheme, long length,
            Map<String, List<String>> headers, String context) {
        if (ProgressiveLoadRetry.isUnknownLengthHttp(scheme, length, headers) != expected) {
            throw new AssertionError(context);
        }
    }

    public static void main(String[] args) {
        Map<String, List<String>> chunked = Map.of("transfer-encoding", List.of("chunked"));
        check(true, "http", -1, chunked, "chunked proxy must reach Dart recovery");
        check(true, "https", -1, Map.of("Content-Type", List.of("audio/ogg")),
                "unknown-length direct offset must reach Dart recovery");
        check(false, "https", -1, Map.of("cOnTeNt-LeNgTh", List.of("1122746")),
                "sized response retains native retry");
        check(false, "https", -1, Map.of("Content-Length", List.of("0")),
                "empty sized response retains default error policy");
        check(false, "https", -1, Map.of("Content-Range", List.of("bytes 100-199/500")),
                "ranged response retains native retry");
        check(false, "https", -1, Map.of("Content-Range", List.of("bytes 100-199/*")),
                "a range has a known body length even without a total");
        check(false, "https", 100, chunked, "bounded data request retains native retry");
        check(false, "file", -1, Collections.emptyMap(), "local errors retain default policy");
        check(false, "https", -1, Collections.emptyMap(), "connection errors retain native retry");
        check(true, "https", -1, Map.of("Content-Length", List.of("-1")),
                "negative length is unknown");
        check(true, "https", -1, Map.of("Content-Length", List.of("invalid")),
                "invalid length is unknown");
        System.out.println("ProgressiveLoadRetryTest: 11 fixtures passed");
    }
}
