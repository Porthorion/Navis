package com.navis.app.navis

import org.junit.Assert.assertEquals
import org.junit.Test
import sun.misc.Unsafe

class JustAudioErrorCodeTest {
    private val unsafe = Unsafe::class.java.getDeclaredField("theUnsafe").let {
        it.isAccessible = true
        it.get(null) as Unsafe
    }

    // Media3 constructors read Android clocks; build the objects field by field.
    private fun put(target: Any, owner: Class<*>, name: String, value: Any?) {
        val offset = unsafe.objectFieldOffset(owner.getDeclaredField(name))
        when (value) {
            is Int -> unsafe.putInt(target, offset, value)
            else -> unsafe.putObject(target, offset, value)
        }
    }

    private fun sourceError(cause: Throwable?): Any {
        val playback = Class.forName("androidx.media3.common.PlaybackException")
        val exo = Class.forName("androidx.media3.exoplayer.ExoPlaybackException")
        val error = unsafe.allocateInstance(exo)
        put(error, Throwable::class.java, "detailMessage", "Source error")
        put(error, Throwable::class.java, "cause", cause ?: error)
        put(error, playback, "errorCode", 2004)
        return error
    }

    private fun describe(error: Any): String {
        val player = Class.forName("com.ryanheise.just_audio.AudioPlayer")
        val method = player.getDeclaredMethod(
            "describeError",
            Class.forName("androidx.media3.common.PlaybackException"),
        )
        method.isAccessible = true
        return method.invoke(null, error) as String
    }

    @Test fun badHttpStatusReachesDartWithItsResponseCode() {
        val http = Class.forName(
            "androidx.media3.datasource.HttpDataSource\$InvalidResponseCodeException",
        )
        val cause = unsafe.allocateInstance(http)
        put(cause, http, "responseCode", 404)
        put(cause, Throwable::class.java, "cause", cause)
        assertEquals("Source error (HTTP 404)", describe(sourceError(cause as Throwable)))
    }

    @Test fun otherFailuresKeepTheirMessage() {
        assertEquals("Source error", describe(sourceError(null)))
    }
}
