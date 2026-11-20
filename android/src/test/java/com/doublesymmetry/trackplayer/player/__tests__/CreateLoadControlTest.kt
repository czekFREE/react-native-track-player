package com.doublesymmetry.trackplayer.player

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.test.utils.FakeTimeline
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(ParameterizedRobolectricTestRunner::class)
@Config(sdk = [24, 28])
class CreateLoadControlTest(mediaUri: String) {
    private val timeline = FakeTimeline(
        FakeTimeline.TimelineWindowDefinition.Builder()
            .setMediaItem(MediaItem.fromUri(mediaUri))
            .setDurationUs(60_000_000)
            .build()
    )

    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun sources() = listOf(
            arrayOf("https://example.invalid/fixture.wav"),
            arrayOf("file:///fixture.wav"),
        )
    }

    @Test
    fun `omitted and zero buffers retain playback and rebuffer thresholds`() {
        listOf(
            BufferOptions(null, null, null, null),
            BufferOptions(0, 0, 0, 0),
        ).forEach { options ->
            val control = createLoadControl(options)
            control.onPrepared(PlayerId.UNSET)
            assertEquals(0L, control.getBackBufferDurationUs(PlayerId.UNSET))
            assertFalse(control.retainBackBufferFromKeyframe(PlayerId.UNSET))
            assertFalse(control.shouldStartPlayback(parameters(bufferedMs = 999)))
            assertTrue(control.shouldStartPlayback(parameters(bufferedMs = 1000)))
            assertFalse(control.shouldStartPlayback(parameters(bufferedMs = 1999, rebuffering = true)))
            assertTrue(control.shouldStartPlayback(parameters(bufferedMs = 2000, rebuffering = true)))
            assertTrue(control.shouldContinueLoading(parameters(bufferedMs = 49999)))
            assertFalse(control.shouldContinueLoading(parameters(bufferedMs = 50000)))
            control.onReleased(PlayerId.UNSET)
        }
    }

    @Test
    fun `custom buffers retain milliseconds and doubled rebuffer threshold`() {
        val control = createLoadControl(BufferOptions(10000, 20000, 1500, 5000))
        control.onPrepared(PlayerId.UNSET)

        assertEquals(5_000_000L, control.getBackBufferDurationUs(PlayerId.UNSET))
        assertFalse(control.shouldStartPlayback(parameters(bufferedMs = 1499)))
        assertTrue(control.shouldStartPlayback(parameters(bufferedMs = 1500)))
        assertFalse(control.shouldStartPlayback(parameters(bufferedMs = 2999, rebuffering = true)))
        assertTrue(control.shouldStartPlayback(parameters(bufferedMs = 3000, rebuffering = true)))
        assertTrue(control.shouldContinueLoading(parameters(bufferedMs = 9999)))
        assertTrue(control.shouldContinueLoading(parameters(bufferedMs = 15000)))
        assertFalse(control.shouldContinueLoading(parameters(bufferedMs = 20000)))
        assertFalse(control.shouldContinueLoading(parameters(bufferedMs = 15000)))
        assertTrue(control.shouldContinueLoading(parameters(bufferedMs = 9999)))
        control.onReleased(PlayerId.UNSET)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `inconsistent buffer limits fail at configuration`() {
        createLoadControl(BufferOptions(10000, 5000, 1000, 0))
    }

    private fun parameters(bufferedMs: Long, rebuffering: Boolean = false) = LoadControl.Parameters(
        PlayerId.UNSET,
        timeline,
        MediaSource.MediaPeriodId(timeline.getUidOfPeriod(0)),
        0L,
        bufferedMs * 1000,
        1f,
        true,
        rebuffering,
        C.TIME_UNSET,
        C.TIME_UNSET,
    )
}
