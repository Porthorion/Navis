package com.navis.app.navis

import android.os.Build
import android.view.HapticFeedbackConstants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class HapticKindsTest {
    private val allKinds = listOf(
        "toggleOn", "toggleOff", "press", "release", "firm", "tick", "frequentTick",
        "contextClick", "confirm", "reject", "thresholdOn", "thresholdOff", "dragStart",
        "dragEnd", "longPress",
    )

    @Test
    fun api34GetsTheRichConstants() {
        val sdk = Build.VERSION_CODES.UPSIDE_DOWN_CAKE
        assertEquals(HapticFeedbackConstants.TOGGLE_ON, HapticKinds.constantFor("toggleOn", sdk))
        assertEquals(HapticFeedbackConstants.TOGGLE_OFF, HapticKinds.constantFor("toggleOff", sdk))
        assertEquals(
            HapticFeedbackConstants.GESTURE_THRESHOLD_ACTIVATE,
            HapticKinds.constantFor("thresholdOn", sdk),
        )
        assertEquals(HapticFeedbackConstants.DRAG_START, HapticKinds.constantFor("dragStart", sdk))
        for (kind in allKinds) assertNotNull(kind, HapticKinds.constantFor(kind, sdk))
    }

    @Test
    fun api30KeepsConfirmButNotTheApi34Constants() {
        val sdk = Build.VERSION_CODES.R
        assertEquals(HapticFeedbackConstants.CONFIRM, HapticKinds.constantFor("confirm", sdk))
        assertEquals(HapticFeedbackConstants.REJECT, HapticKinds.constantFor("reject", sdk))
        assertEquals(HapticFeedbackConstants.GESTURE_END, HapticKinds.constantFor("dragEnd", sdk))
        assertNull(HapticKinds.constantFor("toggleOn", sdk))
        assertNull(HapticKinds.constantFor("thresholdOff", sdk))
        assertNull(HapticKinds.constantFor("frequentTick", sdk))
    }

    @Test
    fun minSdkHasTheOldConstantsOnly() {
        val sdk = Build.VERSION_CODES.N
        assertEquals(HapticFeedbackConstants.VIRTUAL_KEY, HapticKinds.constantFor("press", sdk))
        assertEquals(HapticFeedbackConstants.CLOCK_TICK, HapticKinds.constantFor("tick", sdk))
        assertEquals(HapticFeedbackConstants.LONG_PRESS, HapticKinds.constantFor("longPress", sdk))
        assertEquals(HapticFeedbackConstants.KEYBOARD_TAP, HapticKinds.constantFor("firm", sdk))
        assertEquals(HapticFeedbackConstants.CONTEXT_CLICK, HapticKinds.constantFor("contextClick", sdk))
        assertNull(HapticKinds.constantFor("release", sdk))
        assertNull(HapticKinds.constantFor("confirm", sdk))
    }

    @Test
    fun unknownKindIsNotPlayed() {
        assertNull(HapticKinds.constantFor("nope", Build.VERSION_CODES.UPSIDE_DOWN_CAKE))
    }
}
