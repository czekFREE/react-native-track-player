package com.doublesymmetry.trackplayer.player

import androidx.media3.common.MediaItem
import com.doublesymmetry.trackplayer.model.Track
import java.util.concurrent.atomic.AtomicLong

internal class QueueEntry(val track: Track) {
    val token: Long = nextToken.incrementAndGet()
    private companion object {
        val nextToken = AtomicLong()
    }
}

internal val MediaItem.queueEntry: QueueEntry
    get() = checkNotNull(localConfiguration?.tag as? QueueEntry) {
        "RNTP playlists must contain tracks inserted through RNTPPlaybackController"
    }
