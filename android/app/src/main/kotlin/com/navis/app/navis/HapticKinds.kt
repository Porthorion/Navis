package com.navis.app.navis

import android.os.Build
import android.view.HapticFeedbackConstants

/**
 * Maps the haptic vocabulary in `navis_haptics.dart` to the richest
 * [HapticFeedbackConstants] value the device's API level has. Null means the
 * device lacks it, and Dart plays its Flutter primitive instead.
 */
object HapticKinds {
    fun constantFor(kind: String, sdk: Int): Int? = when (kind) {
        "toggleOn" -> atLeast(sdk, Build.VERSION_CODES.UPSIDE_DOWN_CAKE, HapticFeedbackConstants.TOGGLE_ON)
        "toggleOff" -> atLeast(sdk, Build.VERSION_CODES.UPSIDE_DOWN_CAKE, HapticFeedbackConstants.TOGGLE_OFF)
        "frequentTick" -> atLeast(sdk, Build.VERSION_CODES.UPSIDE_DOWN_CAKE, HapticFeedbackConstants.SEGMENT_FREQUENT_TICK)
        "thresholdOn" -> atLeast(sdk, Build.VERSION_CODES.UPSIDE_DOWN_CAKE, HapticFeedbackConstants.GESTURE_THRESHOLD_ACTIVATE)
        "thresholdOff" -> atLeast(sdk, Build.VERSION_CODES.UPSIDE_DOWN_CAKE, HapticFeedbackConstants.GESTURE_THRESHOLD_DEACTIVATE)
        "dragStart" -> atLeast(sdk, Build.VERSION_CODES.UPSIDE_DOWN_CAKE, HapticFeedbackConstants.DRAG_START)
        "confirm" -> atLeast(sdk, Build.VERSION_CODES.R, HapticFeedbackConstants.CONFIRM)
        "reject" -> atLeast(sdk, Build.VERSION_CODES.R, HapticFeedbackConstants.REJECT)
        "dragEnd" -> atLeast(sdk, Build.VERSION_CODES.R, HapticFeedbackConstants.GESTURE_END)
        "release" -> atLeast(sdk, Build.VERSION_CODES.O_MR1, HapticFeedbackConstants.VIRTUAL_KEY_RELEASE)
        "contextClick" -> atLeast(sdk, Build.VERSION_CODES.M, HapticFeedbackConstants.CONTEXT_CLICK)
        "press" -> HapticFeedbackConstants.VIRTUAL_KEY
        "firm" -> HapticFeedbackConstants.KEYBOARD_TAP
        "tick" -> HapticFeedbackConstants.CLOCK_TICK
        "longPress" -> HapticFeedbackConstants.LONG_PRESS
        else -> null
    }

    private fun atLeast(sdk: Int, minimum: Int, constant: Int): Int? =
        if (sdk >= minimum) constant else null
}
