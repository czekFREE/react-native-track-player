/*
 * Adapted from KotlinAudio AudioItem, copyright 2022 Double Symmetry GmbH.
 * Licensed under Apache-2.0. Modified for RNTP track and occurrence ownership.
 */
package com.doublesymmetry.trackplayer.player

import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata

internal fun createMediaItemForTrack(entry: QueueEntry): MediaItem {
    val track = entry.track
    val extras = Bundle().apply {
        track.headers?.let { putSerializable("headers", HashMap(it)) }
        track.userAgent?.let { putString("user-agent", it) }
        track.resourceId?.let { putInt("resource-id", it) }
        putString("type", track.type.toString())
        putString("uri", track.uri.toString())
    }
    return MediaItem.Builder()
        .setMediaId(track.mediaId ?: track.uri.toString())
        .setUri(track.uri)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(track.title)
                .setArtist(track.artist)
                .setArtworkUri(track.artwork)
                .setExtras(extras)
                .build()
        )
        .setTag(entry)
        .build()
}
