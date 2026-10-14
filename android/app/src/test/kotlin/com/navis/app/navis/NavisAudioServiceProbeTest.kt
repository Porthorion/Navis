package com.navis.app.navis

import com.ryanheise.audioservice.AudioProcessingState
import com.ryanheise.audioservice.NavisAudioServiceProbe
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NavisAudioServiceProbeTest {
    @Test fun pausedAndStoppedSessionsPermitSync() {
        for (state in listOf(AudioProcessingState.idle, AudioProcessingState.ready, AudioProcessingState.completed)) {
            assertFalse(NavisAudioServiceProbe.defersSync(false, state))
        }
    }
    @Test fun playingAndLoadingDeferSync() {
        assertTrue(NavisAudioServiceProbe.defersSync(true, AudioProcessingState.ready))
        assertTrue(NavisAudioServiceProbe.defersSync(false, AudioProcessingState.loading))
        assertTrue(NavisAudioServiceProbe.defersSync(false, AudioProcessingState.buffering))
    }
}
