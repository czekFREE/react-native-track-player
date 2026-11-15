package com.doublesymmetry.trackplayer.player

import android.content.Context
import androidx.media3.common.Player
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
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
    fun commandChangeCallbacksUseTheSameFilteredCapabilitiesAndListenerIdentity() {
        val context: Context = RuntimeEnvironment.getApplication()
        val engine = ExoPlayer.Builder(context).build()
        try {
            val remote = RNTPRemotePlayer(engine) {}
            val commands = mutableListOf<Player.Commands>()
            val listener = object : Player.Listener {
                override fun onAvailableCommandsChanged(availableCommands: Player.Commands) {
                    commands.add(availableCommands)
                }
            }
            remote.addListener(listener)
            remote.addListener(listener)
            engine.addMediaItem(MediaItem.fromUri("https://example.invalid/fixture.mp3"))
            assertEquals(1, commands.size)
            assertFalse(commands.single().contains(Player.COMMAND_SET_MEDIA_ITEM))
            assertFalse(commands.single().contains(Player.COMMAND_CHANGE_MEDIA_ITEMS))
            assertEquals(remote.availableCommands, commands.single())
            remote.removeListener(listener)
            engine.clearMediaItems()
            assertEquals(1, commands.size)
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
