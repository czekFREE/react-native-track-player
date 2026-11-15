package com.doublesymmetry.trackplayer.player

import android.content.Context
import android.net.Uri
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.test.core.app.ApplicationProvider
import java.io.File
import org.junit.Before
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class CreateMediaCacheTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Before
    fun clearCache() {
        File(context.cacheDir, "RNTP").deleteRecursively()
    }

    @Test
    fun `disabled cache allocates no folder or lock`() {
        val directory = File(context.cacheDir, "RNTP")
        directory.deleteRecursively()

        assertNull(createMediaCache(context, 0))
        assertNull(createMediaCache(context, -1))
        assertFalse(directory.exists())
        assertFalse(SimpleCache.isCacheFolderLocked(directory))
    }

    @Test
    fun `release permits a new owner to reopen the same cache`() {
        val directory = File(context.cacheDir, "RNTP")
        val first = requireNotNull(createMediaCache(context, 1))
        assertTrue(SimpleCache.isCacheFolderLocked(directory))
        first.release()
        assertFalse(SimpleCache.isCacheFolderLocked(directory))

        val second = requireNotNull(createMediaCache(context, 1))
        try {
            assertNotSame(first, second)
            assertTrue(SimpleCache.isCacheFolderLocked(directory))
        } finally {
            second.release()
            second.release()
        }
        assertFalse(SimpleCache.isCacheFolderLocked(directory))
    }

    @Test
    fun `release closes the database and permits repeated cleanup`() {
        val database = StandaloneDatabaseProvider(context)
        val sqlite = database.writableDatabase
        val owner = RNTPMediaCache(
            SimpleCache(
                File(context.cacheDir, "RNTP"),
                LeastRecentlyUsedCacheEvictor(1000),
                database,
            ),
            database,
        )
        try {
            assertTrue(sqlite.isOpen)
            owner.release()
            owner.release()
            assertFalse(sqlite.isOpen)
        } finally {
            owner.release()
        }
    }

    @Test
    fun `cache size uses decimal kilobytes and evicts least recently used bytes`() {
        val ownedCache = requireNotNull(createMediaCache(context, 1))
        val cache = ownedCache.cache
        try {
            write(cache, "first", ByteArray(600) { 1 })
            write(cache, "second", ByteArray(410) { 2 })

            assertEquals(410L, cache.cacheSpace)
            assertFalse(cache.isCached("https://example.invalid/first", 0, 600))
            assertTrue(cache.isCached("https://example.invalid/second", 0, 410))
        } finally {
            ownedCache.release()
        }
    }

    private fun write(cache: SimpleCache, name: String, payload: ByteArray) {
        val dataSource = CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory { ByteArrayDataSource(payload) }
            .createDataSource()
        CacheWriter(
            dataSource,
            DataSpec(Uri.parse("https://example.invalid/$name")),
            null,
            null,
        ).cache()
    }
}
