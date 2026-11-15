package com.doublesymmetry.trackplayer.player

import android.content.Context
import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceInputStream
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.RawResourceDataSource
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.smoothstreaming.SsMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.test.core.app.ApplicationProvider
import com.doublesymmetry.trackplayer.model.Track
import java.util.concurrent.TimeUnit
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Before
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class TrackMediaSourceFactoryTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Before
    fun clearCache() {
        java.io.File(context.cacheDir, "RNTP").deleteRecursively()
    }

    @Test
    fun `public track types choose their corresponding media source`() {
        val factory = TrackMediaSourceFactory(context, null)

        assertTrue(factory.createMediaSource(item(type = "default")) is ProgressiveMediaSource)
        assertTrue(factory.createMediaSource(item(type = "dash")) is DashMediaSource)
        assertTrue(factory.createMediaSource(item(type = "hls")) is HlsMediaSource)
        assertTrue(factory.createMediaSource(item(type = "smoothstreaming")) is SsMediaSource)
        assertTrue(factory.createMediaSource(item(type = "unknown")) is ProgressiveMediaSource)
    }

    @Test
    fun `headers and user agent belong only to the requested track`() {
        val server = MockWebServer()
        val payload = "source-fixture"
        repeat(3) { server.enqueue(MockResponse().setBody(payload)) }
        server.start()
        try {
            val url = server.url("/audio").toString()
            val first = item(url = url, userAgent = "first-fixture", header = "first")
            val second = item(url = url, userAgent = "second-fixture", header = "second")
            val plain = item(url = url)
            val factory = TrackMediaSourceFactory(context, null)

            assertArrayEquals(payload.toByteArray(), read(factory.createDataSourceFactory(first), first))
            assertArrayEquals(payload.toByteArray(), read(factory.createDataSourceFactory(second), second))
            assertArrayEquals(payload.toByteArray(), read(factory.createDataSourceFactory(plain), plain))

            assertEquals(3, server.requestCount)
            val firstRequest = requireNotNull(server.takeRequest(2, TimeUnit.SECONDS))
            val secondRequest = requireNotNull(server.takeRequest(2, TimeUnit.SECONDS))
            val plainRequest = requireNotNull(server.takeRequest(2, TimeUnit.SECONDS))
            assertEquals("/audio", firstRequest.path)
            assertEquals("first-fixture", firstRequest.getHeader("User-Agent"))
            assertEquals("first", firstRequest.getHeader("X-Test-Track"))
            assertEquals("/audio", secondRequest.path)
            assertEquals("second-fixture", secondRequest.getHeader("User-Agent"))
            assertEquals("second", secondRequest.getHeader("X-Test-Track"))
            assertEquals("/audio", plainRequest.path)
            assertEquals("react-native-track-player", plainRequest.getHeader("User-Agent"))
            assertNull(plainRequest.getHeader("X-Test-Track"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `network sources follow redirects`() {
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "/audio"))
        server.enqueue(MockResponse().setBody("redirect-fixture"))
        server.start()
        try {
            val mediaItem = item(url = server.url("/redirect").toString())
            val factory = TrackMediaSourceFactory(context, null)
            assertEquals(
                "redirect-fixture",
                read(factory.createDataSourceFactory(mediaItem), mediaItem).decodeToString(),
            )
            assertEquals("/redirect", requireNotNull(server.takeRequest(2, TimeUnit.SECONDS)).path)
            assertEquals("/audio", requireNotNull(server.takeRequest(2, TimeUnit.SECONDS)).path)
            assertEquals(2, server.requestCount)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `downloaded files can be opened repeatedly without networking`() {
        val file = java.io.File.createTempFile("rntp-source-", ".fixture", context.cacheDir)
        file.writeText("download-fixture")
        try {
            val mediaItem = item(url = Uri.fromFile(file).toString())
            val factory = TrackMediaSourceFactory(context, null).createDataSourceFactory(mediaItem)

            assertEquals("download-fixture", read(factory, mediaItem).decodeToString())
            assertEquals("download-fixture", read(factory, mediaItem).decodeToString())
        } finally {
            file.delete()
        }
    }

    @Test
    fun `bundled resources receive a fresh unopened data source for each load`() {
        val resourceId = context.resources.getIdentifier("rntp_test_audio", "raw", context.packageName)
        assertNotEquals(0, resourceId)
        val uri = Uri.parse("rawresource:///$resourceId")
        val track = Track(context, Bundle().apply { putString("url", uri.toString()) }, 0)
        track.resourceId = resourceId
        val mediaItem = createMediaItemForTrack(QueueEntry(track))
        val factory = TrackMediaSourceFactory(context, null).createDataSourceFactory(mediaItem)
        val first = factory.createDataSource()
        val second = factory.createDataSource()
        try {
            assertTrue(first is RawResourceDataSource)
            assertTrue(second is RawResourceDataSource)
            assertNotSame(first, second)
            assertNull(first.uri)
            assertNull(second.uri)
        } finally {
            first.close()
            second.close()
        }
        val expected = context.resources.openRawResource(resourceId).use { it.readBytes() }
        assertTrue(expected.isNotEmpty())
        assertArrayEquals(expected, read(factory, mediaItem))
        assertArrayEquals(expected, read(factory, mediaItem))
    }

    @Test
    fun `cached network bytes remain readable after the upstream stops`() {
        val ownedCache = requireNotNull(createMediaCache(context, 10))
        val cache = ownedCache.cache
        val payload = "cached-fixture"
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody(payload))
        server.start()
        try {
            val mediaItem = item(url = server.url("/audio").toString())
            val factory = TrackMediaSourceFactory(context, cache).createDataSourceFactory(mediaItem)
            try {
                assertArrayEquals(payload.toByteArray(), read(factory, mediaItem))
                assertEquals(payload.length.toLong(), cache.cacheSpace)
                assertEquals(1, server.requestCount)
            } finally {
                server.shutdown()
            }
            assertArrayEquals(payload.toByteArray(), read(factory, mediaItem))
            assertEquals(1, server.requestCount)
        } finally {
            ownedCache.release()
        }
    }

    private fun item(
        type: String = "default",
        url: String = "https://example.invalid/audio",
        userAgent: String? = null,
        header: String? = null,
    ): MediaItem {
        val bundle = Bundle().apply {
            putString("url", url)
            putString("type", type)
            userAgent?.let { putString("userAgent", it) }
            header?.let { value ->
                putBundle("headers", Bundle().apply { putString("X-Test-Track", value) })
            }
        }
        return createMediaItemForTrack(QueueEntry(Track(context, bundle, 0)))
    }

    private fun read(factory: DataSource.Factory, mediaItem: MediaItem): ByteArray =
        DataSourceInputStream(
            factory.createDataSource(),
            DataSpec(requireNotNull(mediaItem.localConfiguration).uri),
        ).use { it.readBytes() }
}
