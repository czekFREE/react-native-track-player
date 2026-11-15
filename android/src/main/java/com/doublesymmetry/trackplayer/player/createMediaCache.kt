/*
 * Adapted from KotlinAudio, Copyright 2022 Double Symmetry GmbH.
 * Licensed under Apache-2.0. Modified to give each RNTP controller cache ownership.
 */
package com.doublesymmetry.trackplayer.player

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

@OptIn(UnstableApi::class)
internal fun createMediaCache(context: Context, sizeKb: Long): RNTPMediaCache? {
    if (sizeKb <= 0) return null
    val database = StandaloneDatabaseProvider(context)
    try {
        return RNTPMediaCache(
            SimpleCache(
                File(context.cacheDir, "RNTP"),
                LeastRecentlyUsedCacheEvictor(sizeKb * 1000),
                database,
            ),
            database,
        )
    } catch (error: Throwable) {
        database.close()
        throw error
    }
}

@OptIn(UnstableApi::class)
internal class RNTPMediaCache(
    val cache: SimpleCache,
    private val database: StandaloneDatabaseProvider,
) {
    private var released = false

    fun release() {
        if (released) return
        released = true
        try {
            cache.release()
        } finally {
            database.close()
        }
    }
}
