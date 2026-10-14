package com.navis.app.navis

import com.ryanheise.audioservice.AudioService
import com.ryanheise.audioservice.AudioServicePlugin
import java.lang.reflect.Modifier
import org.junit.Assert.*
import org.junit.Test

class NavisAudioServiceRecoveryTest {
    @Test fun upstreamReflectionContract() {
        val listener = AudioService::class.java.getDeclaredField("listener")
        val handler = AudioServicePlugin::class.java.getDeclaredField("audioHandlerInterface")
        assertTrue(Modifier.isStatic(listener.modifiers))
        assertTrue(Modifier.isStatic(handler.modifiers))
        assertEquals(AudioService.ServiceListener::class.java, listener.type)
        assertTrue(AudioService.ServiceListener::class.java.isAssignableFrom(handler.type))
    }

    @Test fun appServiceOwnsListenerRecovery() {
        val service = Class.forName("com.ryanheise.audioservice.NavisAudioService", false, javaClass.classLoader)
        assertTrue(AudioService::class.java.isAssignableFrom(service))
        service.getDeclaredMethod("onCreate")
        service.getDeclaredMethod("restoreListener")
    }
}
