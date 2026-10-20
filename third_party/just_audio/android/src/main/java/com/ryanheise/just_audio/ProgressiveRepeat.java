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

    static int restartIndex(boolean owned, boolean playRequested, Object boundaryUid,
            Object currentUid, int currentIndex, long boundaryRevision, long currentRevision) {
        return owned && playRequested && currentIndex >= 0 && boundaryUid != null
                && boundaryUid.equals(currentUid) && boundaryRevision == currentRevision
                ? currentIndex : -1;
    }
}
