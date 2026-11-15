/*
 * Adapted from KotlinAudio BaseAudioPlayer, copyright 2022 Double Symmetry GmbH.
 * Licensed under Apache-2.0. Modified to own RNTP interruption and volume policy.
 */
package com.doublesymmetry.trackplayer.player

import android.content.Context
import android.media.AudioManager
import androidx.core.content.ContextCompat
import androidx.media.AudioAttributesCompat
import androidx.media.AudioFocusRequestCompat
import androidx.media.AudioManagerCompat

internal class RNTPAudioFocusHandler(
    context: Context,
    private val options: PlaybackOptions,
    private val setVolumeMultiplier: (Float) -> Unit,
    private val onFocusChanged: (RNTPPlaybackEvent.FocusChanged) -> Unit,
) {
    private val audioManager = ContextCompat.getSystemService(context, AudioManager::class.java)
    private var request: AudioFocusRequestCompat? = null
    private var hasAudioFocus = false
    private var wasDucking = false

    fun requestFocus() {
        if (hasAudioFocus) return
        val manager = audioManager ?: return
        val focusRequest = AudioFocusRequestCompat.Builder(AudioManagerCompat.AUDIOFOCUS_GAIN)
            .setOnAudioFocusChangeListener(::onAudioFocusChanged)
            .setAudioAttributes(
                AudioAttributesCompat.Builder()
                    .setUsage(AudioAttributesCompat.USAGE_MEDIA)
                    .setContentType(AudioAttributesCompat.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setWillPauseWhenDucked(options.alwaysPauseOnInterruption)
            .build()
        request = focusRequest
        hasAudioFocus = AudioManagerCompat.requestAudioFocus(manager, focusRequest) ==
            AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    internal fun onAudioFocusChanged(change: Int) {
        val permanent = change == AudioManager.AUDIOFOCUS_LOSS
        val paused = when (change) {
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> true
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> options.alwaysPauseOnInterruption
            else -> false
        }
        if (permanent) abandonFocus()
        val duck = change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK &&
            !options.alwaysPauseOnInterruption
        if (duck) {
            setVolumeMultiplier(0.5f)
            wasDucking = true
        } else if (wasDucking) {
            setVolumeMultiplier(1f)
            wasDucking = false
        }
        onFocusChanged(RNTPPlaybackEvent.FocusChanged(paused, permanent))
    }

    fun abandonFocus() {
        val manager = audioManager
        val focusRequest = request
        if (hasAudioFocus && manager != null && focusRequest != null) {
            AudioManagerCompat.abandonAudioFocusRequest(manager, focusRequest)
        }
        hasAudioFocus = false
        request = null
    }
}
