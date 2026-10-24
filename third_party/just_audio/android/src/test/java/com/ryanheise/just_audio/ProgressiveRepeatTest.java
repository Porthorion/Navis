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
        check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, boundaryUid, 2, 3, 7, 7, false) == 2,
                "inserting before the boundary item restarts at its shifted index");
        for (int index : new int[] {1, 2}) {
            check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, boundaryUid, index, 3, 7, 7, false) == index,
                    "middle and last items restart themselves, never the next item");
            check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, otherUid, index + 1, 3, 7, 7, false) == -1,
                    "selecting another song cancels the restart");
        }
        check(ProgressiveRepeat.boundaryAction(1, true, false, boundaryUid, boundaryUid, 1, 3, 7, 7, false) == -1,
                "Pause or Stop cancels playback intent even if native is already paused");
        check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, boundaryUid, 1, 3, 7, 8, false) == -1,
                "a consumed boundary cannot restart twice");
        check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, boundaryUid, 1, 3, 7, 9, false) == -1,
                "Pause then Play or replacing sources invalidates the old boundary");
        check(ProgressiveRepeat.boundaryAction(1, false, true, boundaryUid, boundaryUid, 1, 3, 7, 7, false) == -1,
                "toggling out of repeat one cancels the boundary");
        check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, boundaryUid, 1, 3, 7, 8, false) == -1,
                "toggling off then on cannot revive the old boundary");
        check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, boundaryUid, 1, 3, 8, 8, false) == 1,
                "explicit Play after Pause can create a fresh same-item boundary");
        check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, null, -1, 0, 7, 7, false) == -1,
                "empty playlists cannot repeat");
        check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, boundaryUid, 1, 3, 7, 7, false) == 1,
                "appending preserves the boundary item and its restart");
        check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, otherUid, 1, 3, 7, 7, false) == -1,
                "removing the boundary item cannot restart its replacement at the same index");
        check(ProgressiveRepeat.boundaryAction(1, true, true, boundaryUid, new Object(), 1, 3, 7, 7, false) == -1,
                "replacing the boundary occurrence cannot restart even at the same index");
        check(ProgressiveRepeat.boundaryAction(1, true, true, null, boundaryUid, 1, 3, 7, 7, false) == -1,
                "a missing boundary cannot restart the current item");
        check(ProgressiveRepeat.boundaryAction(2, true, true, boundaryUid, boundaryUid, 2, 3, 7, 7, false) == 0,
                "ALL wraps the last item to the first");
        check(ProgressiveRepeat.boundaryAction(2, true, true, boundaryUid, boundaryUid, 0, 1, 7, 7, false) == 0,
                "single-item ALL restarts itself");
        check(ProgressiveRepeat.boundaryAction(2, true, true, boundaryUid, boundaryUid, 1, 3, 7, 7, false) == ProgressiveRepeat.RESUME,
                "ALL resumes a paused boundary moved to a middle item");
        check(ProgressiveRepeat.boundaryAction(2, true, true, boundaryUid, boundaryUid, 2, 4, 7, 7, false) == ProgressiveRepeat.RESUME,
                "an append resumes the old last item after the native boundary pause");
        check(ProgressiveRepeat.boundaryAction(2, true, true, boundaryUid, boundaryUid, 1, 2, 7, 7, false) == 0,
                "a removal makes the current item wrap when it becomes last");
        for (int mode : new int[] {1, 2}) {
            check(ProgressiveRepeat.boundaryAction(mode, true, false, boundaryUid, boundaryUid, 2, 3, 7, 7, false) == -1,
                    "Pause cancels a pending restart for ONE and ALL");
            check(ProgressiveRepeat.boundaryAction(mode, true, true, boundaryUid, otherUid, 2, 3, 7, 7, false) == -1,
                    "a different occurrence cannot consume the boundary for ONE or ALL");
            check(ProgressiveRepeat.boundaryAction(mode, true, true, boundaryUid, boundaryUid, 2, 3, 7, 8, false) == -1,
                    "a stale revision cannot restart ONE or ALL");
            check(ProgressiveRepeat.boundaryAction(mode, false, true, boundaryUid, boundaryUid, 2, 3, 7, 7, false) == -1,
                    "an ineligible item retains native ONE or ALL");
            check(ProgressiveRepeat.boundaryAction(mode, true, true, null, boundaryUid, 2, 3, 7, 7, false) == -1,
                    "ONE and ALL require a boundary UID");
            check(ProgressiveRepeat.boundaryAction(mode, true, true, boundaryUid, boundaryUid, -1, 0, 7, 7, false) == -1,
                    "ONE and ALL reject an empty queue");
            check(ProgressiveRepeat.boundaryAction(mode, true, true, boundaryUid, boundaryUid, 3, 3, 7, 7, false) == -1,
                    "ONE and ALL reject an index outside the queue");
        }
        check(ProgressiveRepeat.boundaryAction(0, true, true, boundaryUid, boundaryUid, 2, 3, 7, 7, false) == -1,
                "OFF cannot restart even if ownership is stale");
        for (boolean seeking : new boolean[] {false, true}) {
            check(ProgressiveRepeat.boundaryAction(2, true, true, boundaryUid, boundaryUid, 1, 3, 7, 7, seeking)
                    == ProgressiveRepeat.RESUME, "a formerly owned non-last boundary resumes");
            check(ProgressiveRepeat.boundaryAction(2, true, false, boundaryUid, boundaryUid, 1, 3, 7, 7, seeking)
                    == -1, "a paused append or seek must not resume");
            check(ProgressiveRepeat.boundaryAction(2, true, true, boundaryUid, otherUid, 1, 3, 7, 7, seeking)
                    == -1, "a replaced occurrence must not resume");
            check(ProgressiveRepeat.boundaryAction(2, true, true, boundaryUid, boundaryUid, 1, 3, 7, 8, seeking)
                    == -1, "a canceled boundary must not resume");
        }
        for (int mode : new int[] {1, 2}) {
            check(ProgressiveRepeat.boundaryAction(mode, true, true, boundaryUid, boundaryUid, 2, 3, 7, 7, true)
                    == ProgressiveRepeat.RESUME, "a seek during a pending ONE or ALL boundary resumes without wrapping");
            check(ProgressiveRepeat.boundaryAction(mode, false, true, boundaryUid, boundaryUid, 2, 3, 7, 7, true)
                    == -1, "a seek without a pending boundary cannot resume");
            check(ProgressiveRepeat.boundaryAction(mode, true, false, boundaryUid, boundaryUid, 2, 3, 7, 7, true)
                    == -1, "a seek after Pause must stay paused");
        }
        check(ProgressiveRepeat.boundaryAction(0, true, true, boundaryUid, boundaryUid, 2, 3, 7, 7, true)
                == -1, "OFF cannot resume a canceled repeat boundary");
        System.out.println("ProgressiveRepeatTest: " + fixtures + " fixtures passed");
    }
}
