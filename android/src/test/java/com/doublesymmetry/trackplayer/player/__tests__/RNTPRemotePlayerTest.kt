package com.doublesymmetry.trackplayer.player

import android.content.Context
import android.os.Looper
import androidx.media3.common.Player
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class RNTPRemotePlayerTest {
    @Test
    fun remoteActionsEmitExactlyOnceWithoutBypassingJavaScriptTransportPolicy() {
        val context: Context = RuntimeEnvironment.getApplication()
        val engine = ExoPlayer.Builder(context).build()
        try {
            val events = mutableListOf<RNTPPlaybackEvent.Remote>()
            val remote = RNTPRemotePlayer(engine) { events.add(it) }
            remote.play()
            remote.pause()
            remote.seekToNext()
            remote.seekToNextMediaItem()
            remote.seekToPrevious()
            remote.seekToPreviousMediaItem()
            remote.seekForward()
            remote.seekBack()
            remote.stop()
            remote.seekTo(1250L)
            remote.seekTo(1, 2500L)
            assertEquals(listOf(
                RemoteCommand.PLAY, RemoteCommand.PAUSE, RemoteCommand.NEXT, RemoteCommand.NEXT,
                RemoteCommand.PREVIOUS, RemoteCommand.PREVIOUS, RemoteCommand.FORWARD,
                RemoteCommand.REWIND, RemoteCommand.STOP, RemoteCommand.SEEK, RemoteCommand.SEEK,
            ), events.map { it.command })
            assertEquals(listOf(1250L, 2500L), events.filter { it.command == RemoteCommand.SEEK }.map { it.positionMs })
            assertFalse(engine.playWhenReady)
            assertEquals(0L, engine.currentPosition)
        } finally { engine.release() }
    }

    @Test
    fun listenersReceiveJavaDefaultCallbacksAndCanBeRemoved() {
        val context: Context = RuntimeEnvironment.getApplication()
        val engine = ExoPlayer.Builder(context).build()
        try {
            val remote = RNTPRemotePlayer(engine) {}
            val states = mutableListOf<Int>()
            val readyToPlay = mutableListOf<Boolean>()
            val eventPlayers = mutableListOf<Player>()
            val listener = object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    states.add(playbackState)
                }
                override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                    readyToPlay.add(playWhenReady)
                }
                override fun onEvents(player: Player, events: Player.Events) {
                    eventPlayers.add(player)
                }
            }
            remote.addListener(listener)
            remote.addListener(listener)
            engine.addMediaItem(MediaItem.fromUri("https://example.invalid/fixture.mp3"))
            engine.playWhenReady = true
            engine.prepare()
            shadowOf(Looper.getMainLooper()).idle()
            assertTrue(states.contains(Player.STATE_BUFFERING))
            assertEquals(listOf(true), readyToPlay)
            assertTrue(eventPlayers.isNotEmpty())
            assertTrue(eventPlayers.all { it === remote })
            remote.removeListener(listener)
            val callbackCount = states.size + readyToPlay.size + eventPlayers.size
            engine.pause()
            engine.stop()
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(callbackCount, states.size + readyToPlay.size + eventPlayers.size)
        } finally { engine.release() }
    }

    @Test
    fun sessionCannotInsertUnownedMediaItemsIntoThePlaylist() {
        val context: Context = RuntimeEnvironment.getApplication()
        val engine = ExoPlayer.Builder(context).build()
        try {
            val remote = RNTPRemotePlayer(engine) {}
            assertFalse(remote.availableCommands.contains(Player.COMMAND_SET_MEDIA_ITEM))
            assertFalse(remote.availableCommands.contains(Player.COMMAND_CHANGE_MEDIA_ITEMS))
            assertFalse(remote.isCommandAvailable(Player.COMMAND_SET_MEDIA_ITEM))
            assertFalse(remote.isCommandAvailable(Player.COMMAND_CHANGE_MEDIA_ITEMS))
            assertEquals(engine.isCommandAvailable(Player.COMMAND_PLAY_PAUSE), remote.isCommandAvailable(Player.COMMAND_PLAY_PAUSE))
        } finally { engine.release() }
    }
}
