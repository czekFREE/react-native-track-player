/* State transitions adapted from KotlinAudio BaseAudioPlayer, Apache-2.0. */
package com.doublesymmetry.trackplayer.player

import androidx.media3.common.Player
import com.doublesymmetry.trackplayer.model.State

internal fun resolvePlaybackStates(
    initialState: State,
    playbackState: Int,
    hasMediaItem: Boolean,
    playWhenReady: Boolean,
    isPlaying: Boolean,
    events: Player.Events,
): List<State> {
    val states = mutableListOf<State>()
    var state = initialState
    fun update(next: State) {
        if (state != next) {
            state = next
            states.add(next)
        }
    }
    for (index in 0 until events.size()) {
        when (events[index]) {
            Player.EVENT_PLAYBACK_STATE_CHANGED -> when (playbackState) {
                Player.STATE_BUFFERING -> update(State.Buffering)
                Player.STATE_READY -> update(State.Ready)
                Player.STATE_IDLE -> if (state != State.Error && state != State.Stopped) update(State.None)
                Player.STATE_ENDED -> update(if (hasMediaItem) State.Ended else State.None)
            }
            Player.EVENT_MEDIA_ITEM_TRANSITION -> if (hasMediaItem) {
                update(State.Loading)
                if (isPlaying) {
                    update(State.Ready)
                    update(State.Playing)
                }
            }
            Player.EVENT_PLAY_WHEN_READY_CHANGED -> if (!playWhenReady && state != State.Stopped) update(State.Paused)
            Player.EVENT_IS_PLAYING_CHANGED -> if (isPlaying) update(State.Playing)
        }
    }
    return states
}
