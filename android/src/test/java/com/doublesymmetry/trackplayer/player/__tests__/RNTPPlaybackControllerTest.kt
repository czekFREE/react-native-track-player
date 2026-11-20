package com.doublesymmetry.trackplayer.player

import android.content.Context
import android.media.AudioManager
import android.os.Bundle
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.common.TrackSelectionParameters
import com.doublesymmetry.trackplayer.model.MediaType
import com.doublesymmetry.trackplayer.model.State
import com.doublesymmetry.trackplayer.model.Track
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class RNTPPlaybackControllerTest {
    private lateinit var context: Context
    private lateinit var controller: RNTPPlaybackController
    private val events = mutableListOf<RNTPPlaybackEvent>()

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        controller = RNTPPlaybackController(context, PlaybackOptions(handleAudioFocus = false), { events.add(it) })
    }

    @After
    fun tearDown() { controller.release() }

    @Test
    fun emptyQueueAndInitialStateMatchTheBridgeContract() {
        assertEquals(emptyList<Track>(), controller.tracks)
        assertNull(controller.currentTrack)
        assertEquals(0L, controller.duration)
        assertTrue(events.isEmpty())
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(RNTPPlaybackEvent.StateChanged(State.None, null), events.first())
    }

    @Test
    fun forwardBackwardAndEqualMovesReadTheEngineOrder() {
        controller.addTracks(listOf("A", "B", "C", "D").map(::track))
        controller.transportPlayer.moveMediaItem(2, 1)
        assertEquals(listOf("A", "C", "B", "D"), order())
        controller.transportPlayer.moveMediaItem(1, 1)
        assertEquals(listOf("A", "C", "B", "D"), order())
        controller.transportPlayer.moveMediaItem(1, 3)
        assertEquals(listOf("A", "B", "D", "C"), order())
        assertEquals(order(), (0 until 4).map { controller.transportPlayer.getMediaItemAt(it).mediaId })
    }

    @Test
    fun insertionAndMultipleRemovalKeepOriginalTracksAndDuplicateOccurrences() {
        val first = track("same")
        val second = track("same")
        controller.addTracks(listOf(first, track("B")))
        controller.addTracks(listOf(second, track("C")), 1)
        val firstToken = controller.transportPlayer.getMediaItemAt(0).queueEntry.token
        val secondToken = controller.transportPlayer.getMediaItemAt(1).queueEntry.token
        assertNotEquals(firstToken, secondToken)
        controller.removeTracks(listOf(2, 3))
        assertEquals(listOf("same", "same"), order())
        assertSame(first, controller.tracks[0])
        assertSame(second, controller.tracks[1])
        controller.transportPlayer.clearMediaItems()
        assertTrue(controller.tracks.isEmpty())
        controller.addTracks(listOf(first))
        assertNotEquals(firstToken, controller.transportPlayer.getMediaItemAt(0).queueEntry.token)
    }

    @Test
    fun metadataReplacementKeepsOccurrenceAndCustomFields() {
        val track = track("A")
        controller.addTracks(listOf(track))
        val before = controller.transportPlayer.getMediaItemAt(0).queueEntry.token
        track.setMetadata(context, Bundle().apply { putString("title", "Updated") }, 0)
        controller.replaceTrackMetadata(0)
        val mediaItem = controller.transportPlayer.getMediaItemAt(0)
        assertEquals(before, mediaItem.queueEntry.token)
        assertEquals("Updated", mediaItem.mediaMetadata.title)
        assertEquals("custom-A", controller.tracks[0].originalItem.getString("custom"))
    }

    @Test
    fun removingCurrentTrackEmitsItsOriginalIdentityAndPosition() {
        controller.addTracks(listOf("A", "B", "C").map(::track))
        controller.transportPlayer.seekTo(1, 1234)
        shadowOf(Looper.getMainLooper()).idle()
        events.clear()
        controller.removeTracks(listOf(1))
        shadowOf(Looper.getMainLooper()).idle()
        val transition = events.filterIsInstance<RNTPPlaybackEvent.TrackChanged>().single()
        assertEquals("B", transition.previousTrack?.getString("mediaId"))
        assertEquals(1, transition.previousIndex)
        assertEquals(1234L, transition.previousPositionMs)
        assertEquals("C", transition.track?.getString("mediaId"))
        assertEquals(1, transition.index)
    }

    @Test
    fun queuedTransitionPayloadsAreSnapshots() {
        val original = track("A")
        controller.addTracks(listOf(original))
        original.originalItem.putString("custom", "changed-after-event")
        shadowOf(Looper.getMainLooper()).idle()
        val transition = events.filterIsInstance<RNTPPlaybackEvent.TrackChanged>().first()
        assertEquals("custom-A", transition.track?.getString("custom"))
        assertNull(transition.previousIndex)
    }

    @Test
    fun loadReplacesTheQueueWithoutChangingPlayWhenReady() {
        controller.addTracks(listOf("A", "B").map(::track))
        controller.transportPlayer.playWhenReady = true
        controller.load(track("C"))
        assertEquals(listOf("C"), order())
        assertTrue(controller.transportPlayer.playWhenReady)
        controller.stop()
        assertEquals(State.Stopped, controller.state)
        assertFalse(controller.transportPlayer.playWhenReady)
        assertEquals(listOf("C"), order())
    }

    @Test
    fun replacingTheQueuePreservesPlayingAndPausedIntent() {
        for (playWhenReady in listOf(true, false)) {
            controller.addTracks(listOf(track("original")))
            controller.transportPlayer.playWhenReady = playWhenReady

            controller.transportPlayer.clearMediaItems()
            controller.addTracks(listOf(track("replacement")))

            assertEquals(listOf("replacement"), order())
            assertEquals(playWhenReady, controller.transportPlayer.playWhenReady)
        }
    }

    @Test
    fun repeatedSingleItemQueueSkipsAndInitialPositionPreservePlaybackIntent() {
        controller.addTracks(listOf(track("only")))
        controller.transportPlayer.repeatMode = Player.REPEAT_MODE_ALL
        for (playWhenReady in listOf(true, false)) {
            controller.transportPlayer.playWhenReady = playWhenReady

            repeat(2) { controller.transportPlayer.seekToNextMediaItem() }
            controller.transportPlayer.seekTo(8_000)
            controller.transportPlayer.prepare()

            assertEquals("only", controller.currentTrack?.originalItem?.getString("mediaId"))
            assertEquals(playWhenReady, controller.transportPlayer.playWhenReady)
            assertEquals(8_000L, controller.position)
        }
    }

    @Test
    fun stopThenClearAndReloadCannotRestoreOldPlaybackIntent() {
        controller.addTracks(listOf(track("original")))
        controller.transportPlayer.playWhenReady = true

        controller.stop()
        controller.transportPlayer.clearMediaItems()
        controller.addTracks(listOf(track("replacement")))

        assertEquals(listOf("replacement"), order())
        assertFalse(controller.transportPlayer.playWhenReady)
    }

    @Test
    fun conversionRetainsRequestOptionsAndPublicIdentity() {
        val track = track("public")
        track.headers = hashMapOf("X-Test" to "first")
        track.userAgent = "fixture-agent"
        track.type = MediaType.HLS
        val entry = QueueEntry(track)
        val mediaItem = createMediaItemForTrack(entry)
        assertEquals("public", mediaItem.mediaId)
        assertSame(entry, mediaItem.localConfiguration?.tag)
        assertEquals("fixture-agent", mediaItem.mediaMetadata.extras?.getString("user-agent"))
        assertEquals("HLS", mediaItem.mediaMetadata.extras?.getString("type"))
        assertEquals("Episode public", mediaItem.mediaMetadata.title)
    }

    @Test
    fun smoothStreamingPublicTypeIsRecognized() {
        val track = Track(context, Bundle().apply {
            putString("url", "https://example.invalid/manifest")
            putString("type", "smoothstreaming")
        }, 0)
        assertEquals(MediaType.SMOOTH_STREAMING, track.type)
    }

    @Test
    fun repeatShuffleSpeedAndOffloadRemainMedia3Settings() {
        controller.transportPlayer.repeatMode = Player.REPEAT_MODE_ALL
        controller.transportPlayer.shuffleModeEnabled = true
        controller.transportPlayer.setPlaybackSpeed(1.5f)
        controller.setSkipSilence(true)
        controller.setAudioOffload(true)
        assertEquals(Player.REPEAT_MODE_ALL, controller.transportPlayer.repeatMode)
        assertTrue(controller.transportPlayer.shuffleModeEnabled)
        assertEquals(1.5f, controller.transportPlayer.playbackParameters.speed, 0f)
        assertEquals(C.AUDIO_CONTENT_TYPE_MUSIC, controller.transportPlayer.audioAttributes.contentType)
        val engine = controller.transportPlayer as ExoPlayer
        assertTrue(engine.skipSilenceEnabled)
        val preferences = engine.trackSelectionParameters.audioOffloadPreferences
        assertEquals(TrackSelectionParameters.AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_ENABLED, preferences.audioOffloadMode)
        assertTrue(preferences.isGaplessSupportRequired)
        assertTrue(preferences.isSpeedChangeSupportRequired)
        controller.setSkipSilence(false)
        controller.setAudioOffload(false)
        assertFalse(engine.skipSilenceEnabled)
        assertEquals(
            TrackSelectionParameters.AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_DISABLED,
            engine.trackSelectionParameters.audioOffloadPreferences.audioOffloadMode,
        )
    }

    @Test
    fun duckAndRestoreRetainTheRequestedVolumeIncludingChangesDuringDucking() {
        controller.volume = 0.8f
        controller.setVolumeMultiplier(0.5f)
        assertEquals(0.4f, controller.volume, 0f)
        controller.setVolumeMultiplier(1f)
        assertEquals(0.8f, controller.volume, 0f)
        controller.setVolumeMultiplier(0.5f)
        controller.volume = 0.6f
        assertEquals(0.3f, controller.volume, 0f)
        controller.setVolumeMultiplier(1f)
        assertEquals(0.6f, controller.volume, 0f)
    }

    @Test
    fun releaseIsIdempotentAndCancelsPendingEvents() {
        controller.release()
        controller.release()
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(events.isEmpty())
    }

    private fun track(id: String) = Track(context, Bundle().apply {
        putString("url", "https://example.invalid/$id.mp3")
        putString("artwork", "https://example.invalid/art.jpg")
        putString("mediaId", id)
        putString("title", "Episode $id")
        putString("custom", "custom-$id")
    }, 0)

    private fun order() = controller.tracks.map { it.originalItem.getString("mediaId") }
}
