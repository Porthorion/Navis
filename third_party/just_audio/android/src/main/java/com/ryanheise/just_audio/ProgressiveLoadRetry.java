package com.ryanheise.just_audio;

import java.util.List;
import java.util.Map;

final class ProgressiveLoadRetry {
    static boolean isUnknownLengthHttp(String scheme, long requestedLength,
            Map<String, List<String>> responseHeaders) {
        if ((!"http".equalsIgnoreCase(scheme) && !"https".equalsIgnoreCase(scheme))
                || requestedLength >= 0 || responseHeaders.isEmpty()) {
            return false;
        }
        for (Map.Entry<String, List<String>> header : responseHeaders.entrySet()) {
            if ("Content-Length".equalsIgnoreCase(header.getKey())) {
                for (String value : header.getValue()) {
                    try {
                        if (Long.parseLong(value.trim()) >= 0) return false;
                    } catch (NumberFormatException ignored) {
                        // Media3 also ignores malformed content lengths.
                    }
                }
            }
            if ("Content-Range".equalsIgnoreCase(header.getKey())) {
                for (String value : header.getValue()) {
                    if (value.matches("bytes [0-9]+-[0-9]+/([0-9]+|\\*)")) return false;
                }
            }
        }
        return true;
    }
}
