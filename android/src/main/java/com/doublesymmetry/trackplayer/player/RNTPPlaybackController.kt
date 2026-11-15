/*
 * Playback configuration and state interpretation adapted from KotlinAudio,
 * copyright 2022 Double Symmetry GmbH, Apache-2.0. RNTP now owns the Media3
 * playlist, track association, events, and resource lifetime directly.
 */
package com.doublesymmetry.trackplayer.player

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Metadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import com.doublesymmetry.trackplayer.model.State
import com.doublesymmetry.trackplayer.model.Track
import java.util.Locale

@UnstableApi
internal class RNTPPlaybackController(
    context: Context,
    val options: PlaybackOptions = PlaybackOptions(),
    private val onEvent: (RNTPPlaybackEvent) -> Unit,
) {
    private val cache = createMediaCache(context.applicationContext, options.cacheSizeKb)
    private val exoPlayer = try {
        ExoPlayer.Builder(context.applicationContext)
            .setRenderersFactory(
                DefaultRenderersFactory(context.applicationContext)
                    .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
            )
            .setHandleAudioBecomingNoisy(options.handleAudioBecomingNoisy)
            .setMediaSourceFactory(TrackMediaSourceFactory(context.applicationContext, cache?.cache))
            .setLoadControl(createLoadControl(options.bufferOptions))
            .setWakeMode(when (options.wakeMode) {
                1 -> C.WAKE_MODE_LOCAL
                2 -> C.WAKE_MODE_NETWORK
                else -> C.WAKE_MODE_NONE
            })
            .setSkipSilenceEnabled(options.skipSilence)
            .setName("rntp-player")
            .build()
    } catch (error: Exception) {
        cache?.release()
        throw error
    }
    private val handler = Handler(exoPlayer.applicationLooper)
    private var released = false
    private var requestedVolume = 1f
    private var volumeMultiplier = 1f
    private val focus = if (options.handleAudioFocus) null else RNTPAudioFocusHandler(
        context.applicationContext,
        options,
        ::setVolumeMultiplier,
        ::dispatch,
    )
    private val listener = RNTPPlayerListener()

    internal val transportPlayer: Player get() = exoPlayer
    val sessionPlayer: Player = RNTPRemotePlayer(exoPlayer, ::dispatch)
    var state: State = State.None
        private set
    var playbackError: PlaybackError? = null
        private set
    val tracks: List<Track>
        get() = (0 until exoPlayer.mediaItemCount).map { exoPlayer.getMediaItemAt(it).queueEntry.track }
    val currentTrack: Track? get() = exoPlayer.currentMediaItem?.queueEntry?.track
    val duration: Long get() = exoPlayer.duration.takeUnless { it == C.TIME_UNSET } ?: 0
    val position: Long get() = exoPlayer.currentPosition.takeUnless { it == C.INDEX_UNSET.toLong() } ?: 0
    val bufferedPosition: Long get() = exoPlayer.bufferedPosition.takeUnless { it == C.INDEX_UNSET.toLong() } ?: 0
    var volume: Float
        get() = exoPlayer.volume
        set(value) {
            requestedVolume = value
            exoPlayer.volume = value * volumeMultiplier
        }

    init {
        exoPlayer.setAudioAttributes(
            AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(options.audioContentType).build(),
            options.handleAudioFocus,
        )
        exoPlayer.addListener(listener)
        dispatch(RNTPPlaybackEvent.StateChanged(State.None, null))
    }

    internal fun setVolumeMultiplier(multiplier: Float) {
        volumeMultiplier = multiplier
        exoPlayer.volume = requestedVolume * multiplier
    }

    fun addTracks(tracks: List<Track>, insertBeforeIndex: Int = exoPlayer.mediaItemCount) {
        exoPlayer.addMediaItems(insertBeforeIndex, tracks.map { createMediaItemForTrack(QueueEntry(it)) })
        exoPlayer.prepare()
    }

    fun load(track: Track) {
        exoPlayer.setMediaItem(createMediaItemForTrack(QueueEntry(track)))
        exoPlayer.prepare()
    }

    fun removeTracks(indexes: List<Int>) {
        indexes.sortedDescending().forEach(exoPlayer::removeMediaItem)
    }

    fun replaceTrackMetadata(index: Int) {
        val entry = exoPlayer.getMediaItemAt(index).queueEntry
        exoPlayer.replaceMediaItem(index, createMediaItemForTrack(entry))
    }

    fun stop() {
        updateState(State.Stopped)
        exoPlayer.playWhenReady = false
        exoPlayer.stop()
    }

    fun setAudioOffload(enabled: Boolean) {
        val preferences = TrackSelectionParameters.AudioOffloadPreferences.Builder()
            .setAudioOffloadMode(
                if (enabled) TrackSelectionParameters.AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_ENABLED
                else TrackSelectionParameters.AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_DISABLED
            )
            .setIsGaplessSupportRequired(true)
            .setIsSpeedChangeSupportRequired(true)
            .build()
        exoPlayer.trackSelectionParameters = exoPlayer.trackSelectionParameters.buildUpon()
            .setAudioOffloadPreferences(preferences).build()
    }

    fun setSkipSilence(enabled: Boolean) {
        exoPlayer.skipSilenceEnabled = enabled
    }

    fun release() {
        if (released) return
        released = true
        handler.removeCallbacksAndMessages(this)
        focus?.abandonFocus()
        exoPlayer.removeListener(listener)
        try {
            exoPlayer.release()
        } finally {
            cache?.release()
        }
    }

    private fun dispatch(event: RNTPPlaybackEvent) {
        if (released) return
        handler.postAtTime({ if (!released) onEvent(event) }, this, SystemClock.uptimeMillis())
    }

    private fun updateState(value: State) {
        if (state == value) return
        state = value
        dispatch(RNTPPlaybackEvent.StateChanged(value, playbackError))
        if (value == State.Ended && exoPlayer.currentMediaItemIndex == exoPlayer.mediaItemCount - 1) {
            dispatch(RNTPPlaybackEvent.QueueEnded(exoPlayer.currentMediaItemIndex, position))
        }
        when (value) {
            State.None, State.Error -> focus?.abandonFocus()
            State.Ready -> focus?.requestFocus()
            else -> Unit
        }
    }

    private inner class RNTPPlayerListener : Player.Listener {
        private var previousTrack: Track? = null
        private var previousIndex: Int? = null
        private var previousPositionMs: Long = 0
        private var currentEntry: QueueEntry? = null
        private var currentIndex: Int? = null
        private var discontinuityRecorded = false

        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            previousTrack = oldPosition.mediaItem?.queueEntry?.track
            previousIndex = oldPosition.mediaItemIndex.takeIf { oldPosition.mediaItem != null }
            previousPositionMs = oldPosition.positionMs
            discontinuityRecorded = true
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            val entry = mediaItem?.queueEntry
            if (!discontinuityRecorded) {
                previousTrack = currentEntry?.track
                previousIndex = currentIndex
                previousPositionMs = 0
            }
            if (reason != Player.MEDIA_ITEM_TRANSITION_REASON_REPEAT) {
                dispatch(RNTPPlaybackEvent.TrackChanged(
                    previousTrack = previousTrack?.originalItem?.let(::Bundle),
                    previousIndex = previousIndex,
                    previousPositionMs = previousPositionMs,
                    track = entry?.track?.originalItem?.let(::Bundle),
                    index = exoPlayer.currentMediaItemIndex.takeIf { entry != null },
                ))
            }
            currentEntry = entry
            currentIndex = exoPlayer.currentMediaItemIndex.takeIf { entry != null }
            discontinuityRecorded = false
        }

        override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) {
            if (currentEntry?.token == exoPlayer.currentMediaItem?.queueEntry?.token) {
                currentIndex = exoPlayer.currentMediaItemIndex.takeIf { currentEntry != null }
            }
        }

        override fun onMediaMetadataChanged(mediaMetadata: MediaMetadata) {
            dispatch(RNTPPlaybackEvent.CommonMetadata(mediaMetadata))
        }

        override fun onMetadata(metadata: Metadata) {
            dispatch(RNTPPlaybackEvent.TimedMetadata(metadata))
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            dispatch(RNTPPlaybackEvent.PlayWhenReadyChanged(playWhenReady))
        }

        override fun onPlayerError(error: PlaybackException) {
            val playbackError = PlaybackError(
                error.errorCodeName.replace("ERROR_CODE_", "").lowercase(Locale.getDefault()).replace("_", "-"),
                error.message,
            )
            this@RNTPPlaybackController.playbackError = playbackError
            dispatch(RNTPPlaybackEvent.Error(playbackError))
            updateState(State.Error)
        }

        override fun onEvents(player: Player, events: Player.Events) {
            if (events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION)) playbackError = null
            resolvePlaybackStates(
                initialState = state,
                playbackState = player.playbackState,
                hasMediaItem = player.mediaItemCount > 0,
                playWhenReady = player.playWhenReady,
                isPlaying = player.isPlaying,
                events = events,
            ).forEach(::updateState)
            discontinuityRecorded = false
        }
    }
}
