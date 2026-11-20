/*
 * Adapted from KotlinAudio BaseAudioPlayer, copyright 2022 Double Symmetry GmbH.
 * Licensed under Apache-2.0. Modified to dispatch RNTP events without shared flows.
 */
package com.doublesymmetry.trackplayer.player

import androidx.annotation.OptIn
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi

@OptIn(UnstableApi::class)
internal class RNTPRemotePlayer(
    player: Player,
    private val onRemote: (RNTPPlaybackEvent.Remote) -> Unit,
) : ForwardingPlayer(player) {
    override fun play() = send(RemoteCommand.PLAY)
    override fun pause() = send(RemoteCommand.PAUSE)
    override fun stop() = send(RemoteCommand.STOP)
    override fun seekToNext() = send(RemoteCommand.NEXT)
    override fun seekToNextMediaItem() = send(RemoteCommand.NEXT)
    override fun seekToPrevious() = send(RemoteCommand.PREVIOUS)
    override fun seekToPreviousMediaItem() = send(RemoteCommand.PREVIOUS)
    override fun seekForward() = send(RemoteCommand.FORWARD)
    override fun seekBack() = send(RemoteCommand.REWIND)
    override fun seekTo(positionMs: Long) = onRemote(RNTPPlaybackEvent.Remote(RemoteCommand.SEEK, positionMs))
    override fun seekTo(mediaItemIndex: Int, positionMs: Long) = seekTo(positionMs)

    override fun getAvailableCommands(): Player.Commands = filterCommands(super.getAvailableCommands())

    private fun filterCommands(commands: Player.Commands): Player.Commands = commands.buildUpon()
        .removeAll(Player.COMMAND_SET_MEDIA_ITEM, Player.COMMAND_CHANGE_MEDIA_ITEMS)
        .build()

    override fun isCommandAvailable(command: Int): Boolean = availableCommands.contains(command)

    private fun send(command: RemoteCommand) = onRemote(RNTPPlaybackEvent.Remote(command))
}
