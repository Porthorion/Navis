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
        check(ProgressiveRepeat.nativeMode(2, true) == 2,
                "ALL, including a single-song queue, is unchanged");
        Object boundaryUid = new Object();
        Object otherUid = new Object();
        check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, boundaryUid, 2, 7, 7) == 2,
                "inserting before the boundary item restarts at its shifted index");
        for (int index : new int[] {1, 2}) {
            check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, boundaryUid, index, 7, 7) == index,
                    "middle and last items restart themselves, never the next item");
            check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, otherUid, index + 1, 7, 7) == -1,
                    "selecting another song cancels the restart");
        }
        check(ProgressiveRepeat.restartIndex(true, false, boundaryUid, boundaryUid, 1, 7, 7) == -1,
                "Pause or Stop cancels playback intent even if native is already paused");
        check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, boundaryUid, 1, 7, 8) == -1,
                "a consumed boundary cannot restart twice");
        check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, boundaryUid, 1, 7, 9) == -1,
                "Pause then Play or replacing sources invalidates the old boundary");
        check(ProgressiveRepeat.restartIndex(false, true, boundaryUid, boundaryUid, 1, 7, 7) == -1,
                "toggling out of repeat one cancels the boundary");
        check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, boundaryUid, 1, 7, 8) == -1,
                "toggling off then on cannot revive the old boundary");
        check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, boundaryUid, 1, 8, 8) == 1,
                "explicit Play after Pause can create a fresh same-item boundary");
        check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, null, -1, 7, 7) == -1,
                "empty playlists cannot repeat");
        check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, boundaryUid, 1, 7, 7) == 1,
                "appending preserves the boundary item and its restart");
        check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, otherUid, 1, 7, 7) == -1,
                "removing the boundary item cannot restart its replacement at the same index");
        check(ProgressiveRepeat.restartIndex(true, true, boundaryUid, new Object(), 1, 7, 7) == -1,
                "replacing the boundary occurrence cannot restart even at the same index");
        check(ProgressiveRepeat.restartIndex(true, true, null, boundaryUid, 1, 7, 7) == -1,
                "a missing boundary cannot restart the current item");
        System.out.println("ProgressiveRepeatTest: " + fixtures + " fixtures passed");
    }
}
