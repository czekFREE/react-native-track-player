package com.doublesymmetry.trackplayer.player

import android.content.Context
import android.os.Looper
import androidx.media3.common.Player
import com.doublesymmetry.kotlinaudio.models.AudioItem
import com.doublesymmetry.kotlinaudio.models.AudioItemOptions
import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.PlayerOptions
import com.doublesymmetry.kotlinaudio.players.QueuedAudioPlayer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
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
class KotlinAudioBaselineTest {
    private lateinit var player: QueuedAudioPlayer

    @Before
    fun setUp() {
        val context: Context = RuntimeEnvironment.getApplication()
        player = QueuedAudioPlayer(context, PlayerOptions(handleAudioFocus = false))
    }

    @After
    fun tearDown() {
        player.destroy()
    }

    @Test
    fun backwardMoveExposesTheApprovedMirrorDefect() {
        player.add(listOf("A", "B", "C", "D").map(::item))
        player.move(2, 1)
        assertEquals(listOf("A", "C", "B", "D"), engineOrder())
        assertEquals(listOf("C", "A", "B", "D"), player.items.map { it.mediaId })
    }

    @Test
    fun equalIndexMoveChangesOnlyTheBrokenMirror() {
        player.add(listOf("A", "B", "C", "D").map(::item))
        player.move(1, 1)
        assertEquals(listOf("A", "B", "C", "D"), engineOrder())
        assertEquals(listOf("B", "A", "C", "D"), player.items.map { it.mediaId })
    }

    @Test
    fun insertionRemovalAndDuplicatesRetainSourceIdentity() {
        val first = item("duplicate")
        val second = item("duplicate")
        player.add(listOf(first, item("B")))
        player.add(listOf(second), 1)
        player.remove(listOf(2))
        assertEquals(listOf("duplicate", "duplicate"), engineOrder())
        assertSame(first, player.items[0])
        assertSame(second, player.items[1])
    }

    @Test
    fun mediaConversionKeepsPublicIdAndTrackSpecificRequestOptions() {
        val audioItem = AudioItem(
            audioUrl = "https://example.invalid/audio.mp3",
            artwork = "https://example.invalid/art.jpg",
            title = "Episode",
            mediaId = "public-id",
            options = AudioItemOptions(hashMapOf("Authorization" to "fixture"), "fixture-agent", 42)
        )
        val mediaItem = audioItem.toMediaItem()
        assertEquals("public-id", mediaItem.mediaId)
        assertSame(audioItem, mediaItem.localConfiguration?.tag)
        assertEquals("fixture-agent", mediaItem.mediaMetadata.extras?.getString("user-agent"))
        assertEquals(42, mediaItem.mediaMetadata.extras?.getInt("resource-id"))
        assertEquals("Episode", mediaItem.mediaMetadata.title)
    }

    @Test
    fun initialAndExplicitStopStatesRemainDistinguishable() {
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(listOf(AudioPlayerState.IDLE), player.playerEventHolder.stateChange.replayCache)
        player.stop()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(AudioPlayerState.STOPPED, player.playerState)
        assertEquals(listOf(AudioPlayerState.STOPPED), player.playerEventHolder.stateChange.replayCache)
        assertEquals(Player.STATE_IDLE, player.exoPlayer.playbackState)
        assertEquals(false, player.playWhenReady)
    }

    private fun item(id: String) = AudioItem(
        audioUrl = "https://example.invalid/$id.mp3",
        artwork = "https://example.invalid/art.jpg",
        mediaId = id
    )

    private fun engineOrder() = (0 until player.exoPlayer.mediaItemCount).map {
        player.exoPlayer.getMediaItemAt(it).mediaId
    }
}
