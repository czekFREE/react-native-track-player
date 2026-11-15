package com.doublesymmetry.trackplayer.player

import androidx.media3.common.C

internal data class PlaybackOptions(
    val cacheSizeKb: Long = 0,
    val audioContentType: Int = C.AUDIO_CONTENT_TYPE_MUSIC,
    val wakeMode: Int = 0,
    val handleAudioBecomingNoisy: Boolean = true,
    val handleAudioFocus: Boolean = true,
    var alwaysPauseOnInterruption: Boolean = true,
    val bufferOptions: BufferOptions = BufferOptions(null, null, null, null),
    val skipSilence: Boolean = false,
)

internal data class BufferOptions(
    val minBuffer: Int?,
    val maxBuffer: Int?,
    val playBuffer: Int?,
    val backBuffer: Int?,
)
