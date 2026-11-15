package com.doublesymmetry.trackplayer.player

import android.content.Context
import android.media.AudioManager
import androidx.media3.common.Player
import androidx.media3.common.FlagSet
import com.doublesymmetry.trackplayer.model.State
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class RNTPPolicyTest {
    @Test
    fun stateSignalsRetainOrderedLoadingReadyAndPlayingTransitions() {
        assertEquals(
            listOf(State.Loading, State.Ready, State.Playing),
            states(State.Ready, Player.STATE_READY, true, true, true, Player.EVENT_MEDIA_ITEM_TRANSITION),
        )
        assertEquals(listOf(State.Buffering), states(State.Playing, Player.STATE_BUFFERING, true, true, false, Player.EVENT_PLAYBACK_STATE_CHANGED))
        assertEquals(listOf(State.Ready), states(State.Buffering, Player.STATE_READY, true, true, false, Player.EVENT_PLAYBACK_STATE_CHANGED))
        assertEquals(listOf(State.Paused), states(State.Playing, Player.STATE_READY, true, false, false, Player.EVENT_PLAY_WHEN_READY_CHANGED))
        assertEquals(listOf(State.Playing), states(State.Ready, Player.STATE_READY, true, true, true, Player.EVENT_IS_PLAYING_CHANGED))
    }

    @Test
    fun idleSignalsDoNotEraseExplicitStopOrErrorAndEmptyEndedMapsToNone() {
        assertEquals(emptyList<State>(), states(State.Stopped, Player.STATE_IDLE, true, false, false, Player.EVENT_PLAYBACK_STATE_CHANGED, Player.EVENT_PLAY_WHEN_READY_CHANGED))
        assertEquals(emptyList<State>(), states(State.Error, Player.STATE_IDLE, true, true, false, Player.EVENT_PLAYBACK_STATE_CHANGED))
        assertEquals(listOf(State.None), states(State.Playing, Player.STATE_IDLE, false, false, false, Player.EVENT_PLAYBACK_STATE_CHANGED))
        assertEquals(listOf(State.Ended), states(State.Playing, Player.STATE_ENDED, true, true, false, Player.EVENT_PLAYBACK_STATE_CHANGED))
        assertEquals(listOf(State.None), states(State.Playing, Player.STATE_ENDED, false, true, false, Player.EVENT_PLAYBACK_STATE_CHANGED))
    }

    @Test
    fun manualInterruptionPolicyDistinguishesPauseDuckPermanentLossAndGain() {
        val context: Context = RuntimeEnvironment.getApplication()
        val options = PlaybackOptions(alwaysPauseOnInterruption = false)
        val multipliers = mutableListOf<Float>()
        val events = mutableListOf<RNTPPlaybackEvent.FocusChanged>()
        val focus = RNTPAudioFocusHandler(context, options, { multipliers.add(it) }, { events.add(it) })
        focus.onAudioFocusChanged(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        focus.onAudioFocusChanged(AudioManager.AUDIOFOCUS_GAIN)
        focus.onAudioFocusChanged(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        focus.onAudioFocusChanged(AudioManager.AUDIOFOCUS_LOSS)
        assertEquals(listOf(0.5f, 1f), multipliers)
        assertEquals(listOf(
            RNTPPlaybackEvent.FocusChanged(false, false),
            RNTPPlaybackEvent.FocusChanged(false, false),
            RNTPPlaybackEvent.FocusChanged(true, false),
            RNTPPlaybackEvent.FocusChanged(true, true),
        ), events)
        options.alwaysPauseOnInterruption = true
        focus.onAudioFocusChanged(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        assertEquals(RNTPPlaybackEvent.FocusChanged(true, false), events.last())
        assertEquals(listOf(0.5f, 1f), multipliers)
        focus.abandonFocus()
        focus.abandonFocus()
    }

    private fun states(
        initialState: State,
        playbackState: Int,
        hasMediaItem: Boolean,
        playWhenReady: Boolean,
        isPlaying: Boolean,
        vararg eventCodes: Int,
    ) = resolvePlaybackStates(
        initialState, playbackState, hasMediaItem, playWhenReady, isPlaying,
        Player.Events(FlagSet.Builder().addAll(*eventCodes).build()),
    )
}
