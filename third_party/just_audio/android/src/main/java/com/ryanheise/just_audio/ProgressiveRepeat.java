package com.ryanheise.just_audio;

/** Pure decisions for the Android progressive HTTP repeat workaround. */
final class ProgressiveRepeat {
    static final int RESUME = -2;

    static boolean isEligible(String scheme, boolean useDefaultRetry) {
        return !useDefaultRetry && ("http".equalsIgnoreCase(scheme)
                || "https".equalsIgnoreCase(scheme));
    }

    // Media3 OFF/ONE/ALL are 0/1/2; keep the decisions Android-free for JVM fixtures.
    static int nativeMode(int requestedMode, boolean currentEligible, boolean playlistEligible) {
        return ((requestedMode == 1 && currentEligible) || (requestedMode == 2 && playlistEligible))
                ? 0 : requestedMode;
    }

    static boolean pauseAtEnd(int requestedMode, boolean eligible, boolean isLastItem) {
        return eligible && (requestedMode == 1 || (requestedMode == 2 && isLastItem));
    }

    // A boundary that no longer needs a wrap still needs its native pause released.
    static int boundaryAction(int requestedMode, boolean owned, boolean playRequested,
            Object boundaryUid, Object currentUid, int currentIndex, int itemCount,
            long boundaryRevision, long currentRevision, boolean seeking, boolean ended) {
        if (!owned || !playRequested || currentIndex < 0 || currentIndex >= itemCount
                || boundaryUid == null || !boundaryUid.equals(currentUid)
                || boundaryRevision != currentRevision) return -1;
        if (requestedMode < 0 || requestedMode > 2) return -1;
        if (seeking) return RESUME;
        if (requestedMode == 1) return currentIndex;
        if (currentIndex == itemCount - 1) return requestedMode == 2 ? 0 : -1;
        return ended ? currentIndex + 1 : RESUME;
    }
}
