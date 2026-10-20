package com.ryanheise.just_audio;

/** Pure decisions for the Android progressive HTTP repeat-one workaround. */
final class ProgressiveRepeat {
    static boolean isEligible(String scheme, boolean useDefaultRetry) {
        return !useDefaultRetry && ("http".equalsIgnoreCase(scheme)
                || "https".equalsIgnoreCase(scheme));
    }

    // Media3 OFF/ONE/ALL are 0/1/2; keep the decisions Android-free for JVM fixtures.
    static int nativeMode(int requestedMode, boolean eligible) {
        return requestedMode == 1 && eligible ? 0 : requestedMode;
    }

    static int restartIndex(boolean owned, boolean playRequested, int boundaryIndex,
            int currentIndex, long boundaryRevision, long currentRevision) {
        return owned && playRequested && boundaryIndex >= 0
                && boundaryIndex == currentIndex && boundaryRevision == currentRevision
                ? boundaryIndex : -1;
    }
}
