/*
 * Adapted from KotlinAudio, Copyright 2022 Double Symmetry GmbH.
 * Licensed under Apache-2.0. Modified to use RNTP tracks and owned data sources.
 */
package com.doublesymmetry.trackplayer.player

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.RawResourceDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.dash.DefaultDashChunkSource
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.smoothstreaming.DefaultSsChunkSource
import androidx.media3.exoplayer.smoothstreaming.SsMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.extractor.DefaultExtractorsFactory
import com.doublesymmetry.trackplayer.model.MediaType

@OptIn(UnstableApi::class)
internal class TrackMediaSourceFactory(
    private val context: Context,
    private val cache: SimpleCache?,
) : MediaSource.Factory {
    private val supportedMediaSourceFactory = DefaultMediaSourceFactory(context)
    private var drmSessionManagerProvider: DrmSessionManagerProvider? = null
    private var loadErrorHandlingPolicy: LoadErrorHandlingPolicy? = null

    override fun setDrmSessionManagerProvider(provider: DrmSessionManagerProvider): MediaSource.Factory {
        drmSessionManagerProvider = provider
        return this
    }

    override fun setLoadErrorHandlingPolicy(policy: LoadErrorHandlingPolicy): MediaSource.Factory {
        loadErrorHandlingPolicy = policy
        return this
    }

    override fun getSupportedTypes(): IntArray = supportedMediaSourceFactory.supportedTypes

    override fun createMediaSource(mediaItem: MediaItem): MediaSource {
        val dataSourceFactory = createDataSourceFactory(mediaItem)
        val sourceFactory: MediaSource.Factory = when (mediaItem.queueEntry.track.type) {
            MediaType.DASH -> DashMediaSource.Factory(
                DefaultDashChunkSource.Factory(dataSourceFactory),
                dataSourceFactory,
            )
            MediaType.HLS -> HlsMediaSource.Factory(dataSourceFactory)
            MediaType.SMOOTH_STREAMING -> SsMediaSource.Factory(
                DefaultSsChunkSource.Factory(dataSourceFactory),
                dataSourceFactory,
            )
            MediaType.DEFAULT -> ProgressiveMediaSource.Factory(
                dataSourceFactory,
                DefaultExtractorsFactory().setConstantBitrateSeekingEnabled(true),
            )
        }
        drmSessionManagerProvider?.let { sourceFactory.setDrmSessionManagerProvider(it) }
        loadErrorHandlingPolicy?.let { sourceFactory.setLoadErrorHandlingPolicy(it) }
        return sourceFactory.createMediaSource(mediaItem)
    }

    internal fun createDataSourceFactory(mediaItem: MediaItem): DataSource.Factory {
        val track = mediaItem.queueEntry.track
        val uri = requireNotNull(mediaItem.localConfiguration).uri
        if (track.resourceId?.let { it != 0 } == true) {
            return DataSource.Factory { RawResourceDataSource(context) }
        }
        if (isLocalUri(uri)) return DefaultDataSource.Factory(context)

        val httpFactory = DefaultHttpDataSource.Factory()
            .setUserAgent(track.userAgent ?: "react-native-track-player")
            .setAllowCrossProtocolRedirects(true)
            .setDefaultRequestProperties(track.headers ?: emptyMap())
        return cache?.let {
            CacheDataSource.Factory()
                .setCache(it)
                .setUpstreamDataSourceFactory(httpFactory)
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        } ?: httpFactory
    }

    private fun isLocalUri(uri: Uri): Boolean =
        uri.scheme == null ||
            uri.scheme == ContentResolver.SCHEME_FILE ||
            uri.scheme == ContentResolver.SCHEME_ANDROID_RESOURCE ||
            uri.scheme == ContentResolver.SCHEME_CONTENT ||
            uri.scheme == "res" ||
            uri.host == null
}
