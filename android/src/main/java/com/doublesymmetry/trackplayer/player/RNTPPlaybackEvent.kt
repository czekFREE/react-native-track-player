package com.doublesymmetry.trackplayer.player

import androidx.annotation.OptIn
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Metadata
import androidx.media3.common.util.UnstableApi
import com.doublesymmetry.trackplayer.model.State
import android.os.Bundle

internal sealed interface RNTPPlaybackEvent {
    data class StateChanged(val state: State, val error: PlaybackError?) : RNTPPlaybackEvent
    data class TrackChanged(
        val previousTrack: Bundle?,
        val previousIndex: Int?,
        val previousPositionMs: Long,
        val track: Bundle?,
        val index: Int?,
    ) : RNTPPlaybackEvent
    data class FocusChanged(val paused: Boolean, val permanent: Boolean) : RNTPPlaybackEvent
    data class Remote(val command: RemoteCommand, val positionMs: Long = 0) : RNTPPlaybackEvent
    @OptIn(UnstableApi::class)
    data class TimedMetadata(val metadata: Metadata) : RNTPPlaybackEvent
    data class CommonMetadata(val metadata: MediaMetadata) : RNTPPlaybackEvent
    data class PlayWhenReadyChanged(val playWhenReady: Boolean) : RNTPPlaybackEvent
    data class Error(val error: PlaybackError) : RNTPPlaybackEvent
    data class QueueEnded(val index: Int, val positionMs: Long) : RNTPPlaybackEvent
}

internal enum class RemoteCommand { PLAY, PAUSE, NEXT, PREVIOUS, FORWARD, REWIND, STOP, SEEK }

data class PlaybackError(val code: String?, val message: String?)
