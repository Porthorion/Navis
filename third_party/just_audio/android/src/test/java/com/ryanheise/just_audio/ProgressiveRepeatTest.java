package com.ryanheise.just_audio;

/** Executable JVM fixtures; 0/1/2 are Media3's OFF/ONE/ALL constants. */
public final class ProgressiveRepeatTest {
    private static int fixtures;

    private static void check(boolean condition, String context) {
        if (!condition) throw new AssertionError(context);
        fixtures++;
    }

    public static void main(String[] args) {
        check(ProgressiveRepeat.nativeMode(1, true) == 0,
                "progressive repeat one must disable native preloading of itself");
        check(ProgressiveRepeat.isEligible("http", false), "loopback proxy is eligible");
        check(ProgressiveRepeat.isEligible("HTTPS", false), "direct HTTP is eligible");
        check(!ProgressiveRepeat.isEligible("file", false), "local files retain native looping");
        check(!ProgressiveRepeat.isEligible("asset", false), "assets retain native looping");
        check(!ProgressiveRepeat.isEligible(null, false), "missing scheme is ineligible");
        check(!ProgressiveRepeat.isEligible("https", true), "radio opt-out retains native looping");
        check(ProgressiveRepeat.nativeMode(1, false) == 1, "ineligible ONE is unchanged");
        check(ProgressiveRepeat.nativeMode(0, true) == 0, "OFF is unchanged");
        check(ProgressiveRepeat.nativeMode(2, true) == 0,
                "progressive ALL must disable native lookahead wrapping");
        check(ProgressiveRepeat.nativeMode(2, false) == 2, "ineligible ALL stays native");
        for (boolean last : new boolean[] {false, true}) {
            check(ProgressiveRepeat.pauseAtEnd(1, true, last), "ONE pauses at every item");
            check(ProgressiveRepeat.pauseAtEnd(2, true, last) == last,
                    "ALL pauses only at the last item, including a one-item queue");
            check(!ProgressiveRepeat.pauseAtEnd(0, true, last), "OFF never pauses at item end");
            for (int mode : new int[] {0, 1, 2}) {
                check(!ProgressiveRepeat.pauseAtEnd(mode, false, last),
                        "ineligible items never pause for owned repeat");
            }
        }
        Object boundaryUid = new Object();
        Object otherUid = new Object();
        check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, boundaryUid, 2, 3, 7, 7) == 2,
                "inserting before the boundary item restarts at its shifted index");
        for (int index : new int[] {1, 2}) {
            check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, boundaryUid, index, 3, 7, 7) == index,
                    "middle and last items restart themselves, never the next item");
            check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, otherUid, index + 1, 3, 7, 7) == -1,
                    "selecting another song cancels the restart");
        }
        check(ProgressiveRepeat.restartIndex(1, true, false, boundaryUid, boundaryUid, 1, 3, 7, 7) == -1,
                "Pause or Stop cancels playback intent even if native is already paused");
        check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, boundaryUid, 1, 3, 7, 8) == -1,
                "a consumed boundary cannot restart twice");
        check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, boundaryUid, 1, 3, 7, 9) == -1,
                "Pause then Play or replacing sources invalidates the old boundary");
        check(ProgressiveRepeat.restartIndex(1, false, true, boundaryUid, boundaryUid, 1, 3, 7, 7) == -1,
                "toggling out of repeat one cancels the boundary");
        check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, boundaryUid, 1, 3, 7, 8) == -1,
                "toggling off then on cannot revive the old boundary");
        check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, boundaryUid, 1, 3, 8, 8) == 1,
                "explicit Play after Pause can create a fresh same-item boundary");
        check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, null, -1, 0, 7, 7) == -1,
                "empty playlists cannot repeat");
        check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, boundaryUid, 1, 3, 7, 7) == 1,
                "appending preserves the boundary item and its restart");
        check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, otherUid, 1, 3, 7, 7) == -1,
                "removing the boundary item cannot restart its replacement at the same index");
        check(ProgressiveRepeat.restartIndex(1, true, true, boundaryUid, new Object(), 1, 3, 7, 7) == -1,
                "replacing the boundary occurrence cannot restart even at the same index");
        check(ProgressiveRepeat.restartIndex(1, true, true, null, boundaryUid, 1, 3, 7, 7) == -1,
                "a missing boundary cannot restart the current item");
        check(ProgressiveRepeat.restartIndex(2, true, true, boundaryUid, boundaryUid, 2, 3, 7, 7) == 0,
                "ALL wraps the last item to the first");
        check(ProgressiveRepeat.restartIndex(2, true, true, boundaryUid, boundaryUid, 0, 1, 7, 7) == 0,
                "single-item ALL restarts itself");
        check(ProgressiveRepeat.restartIndex(2, true, true, boundaryUid, boundaryUid, 1, 3, 7, 7) == -1,
                "ALL lets middle items auto-advance");
        check(ProgressiveRepeat.restartIndex(2, true, true, boundaryUid, boundaryUid, 2, 4, 7, 7) == -1,
                "an append makes the old last item auto-advance");
        check(ProgressiveRepeat.restartIndex(2, true, true, boundaryUid, boundaryUid, 1, 2, 7, 7) == 0,
                "a removal makes the current item wrap when it becomes last");
        for (int mode : new int[] {1, 2}) {
            check(ProgressiveRepeat.restartIndex(mode, true, false, boundaryUid, boundaryUid, 2, 3, 7, 7) == -1,
                    "Pause cancels a pending restart for ONE and ALL");
            check(ProgressiveRepeat.restartIndex(mode, true, true, boundaryUid, otherUid, 2, 3, 7, 7) == -1,
                    "a different occurrence cannot consume the boundary for ONE or ALL");
            check(ProgressiveRepeat.restartIndex(mode, true, true, boundaryUid, boundaryUid, 2, 3, 7, 8) == -1,
                    "a stale revision cannot restart ONE or ALL");
            check(ProgressiveRepeat.restartIndex(mode, false, true, boundaryUid, boundaryUid, 2, 3, 7, 7) == -1,
                    "an ineligible item retains native ONE or ALL");
            check(ProgressiveRepeat.restartIndex(mode, true, true, null, boundaryUid, 2, 3, 7, 7) == -1,
                    "ONE and ALL require a boundary UID");
            check(ProgressiveRepeat.restartIndex(mode, true, true, boundaryUid, boundaryUid, -1, 0, 7, 7) == -1,
                    "ONE and ALL reject an empty queue");
            check(ProgressiveRepeat.restartIndex(mode, true, true, boundaryUid, boundaryUid, 3, 3, 7, 7) == -1,
                    "ONE and ALL reject an index outside the queue");
        }
        check(ProgressiveRepeat.restartIndex(0, true, true, boundaryUid, boundaryUid, 2, 3, 7, 7) == -1,
                "OFF cannot restart even if ownership is stale");
        System.out.println("ProgressiveRepeatTest: " + fixtures + " fixtures passed");
    }
}
