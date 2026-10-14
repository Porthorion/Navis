package com.navis.app.navis

import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import sun.misc.Unsafe

class JustAudioRecoveryPositionTest {
    @Test fun sourceErrorPublishesTheCurrentNativePositionBeforeIdle() {
        // Construct only the event bridge under test, without an Android Looper
        // or an audio device. Its actual error method still builds the event.
        val unsafeField = Unsafe::class.java.getDeclaredField("theUnsafe")
        unsafeField.isAccessible = true
        val unsafe = unsafeField.get(null) as Unsafe
        val playerClass = Class.forName("com.ryanheise.just_audio.AudioPlayer")
        val bridge = unsafe.allocateInstance(playerClass)
        fun set(name: String, value: Any?) {
            val field = playerClass.getDeclaredField(name)
            field.isAccessible = true
            field.set(bridge, value)
        }
        val exoClass = Class.forName("androidx.media3.exoplayer.ExoPlayer")
        val exo = Proxy.newProxyInstance(exoClass.classLoader, arrayOf(exoClass)) { _, method, _ ->
            when (method.name) {
                "getCurrentPosition" -> 97_000L
                "getBufferedPosition" -> 98_000L
                "getDuration" -> 180_000L
                else -> throw AssertionError("Unexpected native call: ${method.name}")
            }
        }
        val stateClass = Class.forName("com.ryanheise.just_audio.AudioPlayer\$ProcessingState")
        set("player", exo)
        set("processingState", stateClass.enumConstants.first { it.toString() == "ready" })
        set("updatePosition", 42_000L)
        set("updateTime", 1L)
        val channelClass = Class.forName("com.ryanheise.just_audio.BetterEventChannel")
        val channel = unsafe.allocateInstance(channelClass)
        val sinkClass = Class.forName("io.flutter.plugin.common.EventChannel\$EventSink")
        var event: Map<*, *>? = null
        var errorPosition: Long? = null
        val sink = Proxy.newProxyInstance(sinkClass.classLoader, arrayOf(sinkClass)) { _, method, args ->
            if (method.name == "success") event = args[0] as Map<*, *>
            if (method.name == "error") {
                val position = playerClass.getDeclaredField("updatePosition")
                position.isAccessible = true
                errorPosition = position.getLong(bridge)
            }
            null
        }
        val sinkField = channelClass.getDeclaredField("eventSink")
        sinkField.isAccessible = true
        sinkField.set(channel, sink)
        set("eventChannel", channel)
        val error = playerClass.getDeclaredMethod(
            "sendError", Int::class.javaPrimitiveType, String::class.java, Any::class.java,
        )
        error.isAccessible = true
        error.invoke(bridge, 0, "fixture source error", null)
        assertEquals(97_000L, errorPosition)
        assertEquals(97_000_000L, event!!["updatePosition"])
        assertEquals(0, event!!["processingState"])
        assertTrue((event!!["updateTime"] as Long) > 1L)
    }
}
