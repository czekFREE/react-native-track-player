package com.doublesymmetry.trackplayer.player

import android.content.Context
import android.os.Bundle
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import com.google.common.util.concurrent.ListenableFuture
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.doublesymmetry.trackplayer.model.State
import com.doublesymmetry.trackplayer.model.Track
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RNTPPlaybackInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext

    @Test
    fun localPcmDecodesAdvancesAndEndsExactlyOnce() {
        val audioFile = createWaveFile()
        val events = CopyOnWriteArrayList<RNTPPlaybackEvent>()
        val ended = CountDownLatch(1)
        var controller: RNTPPlaybackController? = null
        try {
            instrumentation.runOnMainSync {
                val playback = RNTPPlaybackController(context, PlaybackOptions(handleAudioFocus = false)) {
                    events.add(it)
                    if (it is RNTPPlaybackEvent.QueueEnded) ended.countDown()
                }
                controller = playback
                playback.addTracks(listOf(track("A", audioFile), track("B", audioFile)))
                playback.transportPlayer.play()
            }
            assertTrue("Local PCM queue must reach its end", ended.await(20, TimeUnit.SECONDS))
            val transitions = events.filterIsInstance<RNTPPlaybackEvent.TrackChanged>()
            assertEquals(listOf("A", "B"), transitions.map { it.track?.getString("mediaId") })
            assertEquals("A", transitions[1].previousTrack?.getString("mediaId"))
            assertEquals(0, transitions[1].previousIndex)
            assertTrue(transitions[1].previousPositionMs >= 300)
            val queueEnded = events.filterIsInstance<RNTPPlaybackEvent.QueueEnded>().single()
            assertEquals(1, queueEnded.index)
            assertTrue(queueEnded.positionMs >= 300)
            val states = events.filterIsInstance<RNTPPlaybackEvent.StateChanged>().map { it.state }
            assertEquals(State.None, states.first())
            assertTrue(states.contains(State.Playing))
            assertEquals(State.Ended, states.last())
            val endedStateIndex = events.indexOfFirst {
                it is RNTPPlaybackEvent.StateChanged && it.state == State.Ended
            }
            val queueEndedIndex = events.indexOfFirst { it is RNTPPlaybackEvent.QueueEnded }
            assertTrue(endedStateIndex >= 0 && endedStateIndex < queueEndedIndex)
            assertTrue(events.none { it is RNTPPlaybackEvent.Error })
        } finally {
            instrumentation.runOnMainSync { controller?.release() }
            audioFile.delete()
        }
    }

    @Test
    fun sessionControllerObservesPlayingAndPausedStateAcrossPlaylistChanges() {
        val audioFile = createWaveFile()
        val playing = CountDownLatch(1)
        val paused = CountDownLatch(1)
        var playback: RNTPPlaybackController? = null
        var session: MediaSession? = null
        var connection: ListenableFuture<MediaController>? = null
        try {
            instrumentation.runOnMainSync {
                val configured = RNTPPlaybackController(context, PlaybackOptions(handleAudioFocus = false), {})
                playback = configured
                val mediaSession = MediaSession.Builder(context, configured.sessionPlayer)
                    .setId("rntp-listener-regression")
                    .setCallback(object : MediaSession.Callback {
                        override fun onConnect(
                            session: MediaSession,
                            controller: MediaSession.ControllerInfo,
                        ): MediaSession.ConnectionResult =
                            MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                                .setAvailablePlayerCommands(
                                    MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS.buildUpon()
                                        .removeAll(Player.COMMAND_SET_MEDIA_ITEM, Player.COMMAND_CHANGE_MEDIA_ITEMS)
                                        .build()
                                ).build()
                    }).build()
                session = mediaSession
                connection = MediaController.Builder(context, mediaSession.token).buildAsync()
            }
            val remote = checkNotNull(connection).get(10, TimeUnit.SECONDS)
            instrumentation.runOnMainSync {
                remote.addListener(object : Player.Listener {
                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        if (isPlaying) playing.countDown() else if (playing.count == 0L) paused.countDown()
                    }
                })
                val configured = checkNotNull(playback)
                configured.transportPlayer.repeatMode = Player.REPEAT_MODE_ONE
                configured.addTracks(listOf(track("A", audioFile)))
                configured.transportPlayer.play()
            }
            assertTrue("MediaSession controller must observe actual playback", playing.await(20, TimeUnit.SECONDS))
            instrumentation.runOnMainSync {
                assertTrue(remote.isPlaying)
                assertEquals(Player.STATE_READY, remote.playbackState)
                assertFalse(remote.isCommandAvailable(Player.COMMAND_SET_MEDIA_ITEM))
                assertFalse(remote.isCommandAvailable(Player.COMMAND_CHANGE_MEDIA_ITEMS))
                val configured = checkNotNull(playback)
                configured.addTracks(listOf(track("B", audioFile)))
                configured.transportPlayer.pause()
            }
            assertTrue("MediaSession controller must observe the pause", paused.await(10, TimeUnit.SECONDS))
            instrumentation.runOnMainSync {
                assertFalse(remote.isPlaying)
                assertFalse(remote.isCommandAvailable(Player.COMMAND_SET_MEDIA_ITEM))
                assertFalse(remote.isCommandAvailable(Player.COMMAND_CHANGE_MEDIA_ITEMS))
            }
        } finally {
            instrumentation.runOnMainSync {
                connection?.let(MediaController::releaseFuture)
                session?.release()
                playback?.release()
            }
            audioFile.delete()
        }
    }

    @Test
    fun repeatOneDoesNotEmitActiveTrackChangesOrQueueEndedForEachLoop() {
        val audioFile = createWaveFile()
        val events = CopyOnWriteArrayList<RNTPPlaybackEvent>()
        val repeated = CountDownLatch(2)
        var controller: RNTPPlaybackController? = null
        try {
            instrumentation.runOnMainSync {
                val playback = RNTPPlaybackController(context, PlaybackOptions(handleAudioFocus = false)) {
                    events.add(it)
                }
                controller = playback
                playback.transportPlayer.repeatMode = Player.REPEAT_MODE_ONE
                playback.transportPlayer.addListener(object : Player.Listener {
                    override fun onMediaItemTransition(mediaItem: androidx.media3.common.MediaItem?, reason: Int) {
                        if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_REPEAT) repeated.countDown()
                    }
                })
                playback.addTracks(listOf(track("loop", audioFile)))
                playback.transportPlayer.play()
            }
            assertTrue("Real player must complete at least two repeats", repeated.await(20, TimeUnit.SECONDS))
            instrumentation.runOnMainSync {
                checkNotNull(controller).transportPlayer.pause()
                assertEquals("loop", checkNotNull(controller).currentTrack?.mediaId)
            }
            assertEquals(listOf("loop"), events.filterIsInstance<RNTPPlaybackEvent.TrackChanged>().map {
                it.track?.getString("mediaId")
            })
            assertTrue(events.none { it is RNTPPlaybackEvent.QueueEnded })
            assertTrue(events.none { it is RNTPPlaybackEvent.Error })
        } finally {
            instrumentation.runOnMainSync { controller?.release() }
            audioFile.delete()
        }
    }

    @Test
    fun realPlayerQueueUsesMedia3OrderAcrossMovesAndCurrentRemoval() {
        val audioFile = createWaveFile()
        var controller: RNTPPlaybackController? = null
        try {
            instrumentation.runOnMainSync {
                val playback = RNTPPlaybackController(context, onEvent = {})
                controller = playback
                playback.addTracks(listOf("A", "B", "C", "D").map { track(it, audioFile) })
                playback.transportPlayer.moveMediaItem(2, 1)
                assertEquals(listOf("A", "C", "B", "D"), order(playback))
                playback.transportPlayer.moveMediaItem(1, 1)
                assertEquals(listOf("A", "C", "B", "D"), order(playback))
                playback.transportPlayer.seekTo(1, 100L)
                playback.removeTracks(listOf(1))
                assertEquals(listOf("A", "B", "D"), order(playback))
                assertEquals("B", playback.currentTrack?.mediaId)
                playback.transportPlayer.clearMediaItems()
                assertNull(playback.currentTrack)
                assertEquals(emptyList<String>(), order(playback))
            }
        } finally {
            instrumentation.runOnMainSync { controller?.release() }
            audioFile.delete()
        }
    }

    @Test
    fun cacheAndPlayerCanBeReleasedRepeatedlyAndReopened() {
        instrumentation.runOnMainSync {
            repeat(2) {
                val playback = RNTPPlaybackController(context, PlaybackOptions(cacheSizeKb = 64), {})
                playback.release()
                playback.release()
            }
        }
    }

    @Test
    fun unavailableLocalSourceReportsAndroidErrorAndCanLoadReachableTrack() {
        val audioFile = createWaveFile()
        val error = CountDownLatch(1)
        val ended = CountDownLatch(1)
        val events = CopyOnWriteArrayList<RNTPPlaybackEvent>()
        var controller: RNTPPlaybackController? = null
        try {
            instrumentation.runOnMainSync {
                val playback = RNTPPlaybackController(context, PlaybackOptions(handleAudioFocus = false)) {
                    events.add(it)
                    if (it is RNTPPlaybackEvent.Error) error.countDown()
                    if (it is RNTPPlaybackEvent.QueueEnded) ended.countDown()
                }
                controller = playback
                playback.load(track("missing", File(context.cacheDir, "rntp-missing-${System.nanoTime()}.wav")))
                playback.transportPlayer.play()
            }
            assertTrue("Missing source must report an error", error.await(15, TimeUnit.SECONDS))
            assertEquals("io-file-not-found", events.filterIsInstance<RNTPPlaybackEvent.Error>().single().error.code)
            instrumentation.runOnMainSync {
                checkNotNull(controller).load(track("recovered", audioFile))
                checkNotNull(controller).transportPlayer.play()
            }
            assertTrue("Reachable source must recover after an error", ended.await(20, TimeUnit.SECONDS))
            assertEquals("recovered", events.filterIsInstance<RNTPPlaybackEvent.TrackChanged>().last().track?.getString("mediaId"))
            assertEquals(1, events.filterIsInstance<RNTPPlaybackEvent.QueueEnded>().size)
        } finally {
            instrumentation.runOnMainSync { controller?.release() }
            audioFile.delete()
        }
    }

    private fun track(id: String, file: File) = Track(context, Bundle().apply {
        putString("url", file.toURI().toString())
        putString("mediaId", id)
        putString("title", "Fixture $id")
    }, 0)

    private fun order(playback: RNTPPlaybackController) = playback.tracks.map { it.mediaId }

    private fun createWaveFile(): File {
        val sampleRate = 8000
        val sampleCount = 4000
        val dataSize = sampleCount * 2
        val buffer = ByteBuffer.allocate(44 + dataSize).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray(Charsets.US_ASCII)).putInt(36 + dataSize)
        buffer.put("WAVEfmt ".toByteArray(Charsets.US_ASCII)).putInt(16)
        buffer.putShort(1).putShort(1).putInt(sampleRate).putInt(sampleRate * 2)
        buffer.putShort(2).putShort(16)
        buffer.put("data".toByteArray(Charsets.US_ASCII)).putInt(dataSize)
        repeat(sampleCount) { buffer.putShort(if (it % 16 < 8) 1000 else -1000) }
        return File.createTempFile("rntp-playback-", ".wav", context.cacheDir).apply { writeBytes(buffer.array()) }
    }
}
