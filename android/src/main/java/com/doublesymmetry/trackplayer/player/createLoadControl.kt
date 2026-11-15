/*
 * Adapted from KotlinAudio, Copyright 2022 Double Symmetry GmbH.
 * Licensed under Apache-2.0. Modified for RNTP-owned options.
 */
package com.doublesymmetry.trackplayer.player

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl

@OptIn(UnstableApi::class)
internal fun createLoadControl(bufferOptions: BufferOptions): DefaultLoadControl {
    val rebufferMultiplier = DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS /
        DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_MS
    val minBuffer = bufferOptions.minBuffer?.takeIf { it != 0 }
        ?: DefaultLoadControl.DEFAULT_MIN_BUFFER_MS
    val maxBuffer = bufferOptions.maxBuffer?.takeIf { it != 0 }
        ?: DefaultLoadControl.DEFAULT_MAX_BUFFER_MS
    val playBuffer = bufferOptions.playBuffer?.takeIf { it != 0 }
        ?: DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_MS
    val backBuffer = bufferOptions.backBuffer?.takeIf { it != 0 }
        ?: DefaultLoadControl.DEFAULT_BACK_BUFFER_DURATION_MS

    return DefaultLoadControl.Builder()
        .setBufferDurationsMs(minBuffer, maxBuffer, playBuffer, playBuffer * rebufferMultiplier)
        .setBackBuffer(backBuffer, false)
        .build()
}
