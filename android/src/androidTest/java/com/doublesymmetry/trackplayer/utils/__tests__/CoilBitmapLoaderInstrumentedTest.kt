package com.doublesymmetry.trackplayer.utils

import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@OptIn(UnstableApi::class)
@RunWith(AndroidJUnit4::class)
class CoilBitmapLoaderInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test
    fun imageBytesDecodeAtTheirOriginalSize() {
        val future = onMain { CoilBitmapLoader(context).decodeBitmap(createImageBytes()) }
        val bitmap = future.get(10, TimeUnit.SECONDS)

        assertEquals(16, bitmap.width)
        assertEquals(8, bitmap.height)
    }

    @Test
    fun invalidImageBytesReportAnIoFailure() {
        val future = onMain { CoilBitmapLoader(context).decodeBitmap(byteArrayOf(1, 2, 3)) }
        val error = assertThrows(ExecutionException::class.java) {
            future.get(10, TimeUnit.SECONDS)
        }

        assertTrue(error.cause is IOException)
    }

    @Test
    fun artworkFilesLoadWithOptionalSquareCropping() {
        val file = File.createTempFile("rntp-artwork-", ".png", context.cacheDir)
        try {
            file.writeBytes(createImageBytes())

            listOf(false, true).forEach { cropSquare ->
                val future = onMain {
                    CoilBitmapLoader(context, cropSquare).loadBitmap(Uri.fromFile(file))
                }
                val bitmap = future.get(10, TimeUnit.SECONDS)

                val expectedWidth = if (cropSquare || Build.MANUFACTURER == "samsung") 8 else 16
                assertEquals(expectedWidth, bitmap.width)
                assertEquals(8, bitmap.height)
            }
        } finally {
            file.delete()
        }
    }

    @Test
    fun unavailableArtworkFilesReportAnIoFailure() {
        val file = File(context.cacheDir, "rntp-missing-artwork-${System.nanoTime()}.png")
        val future = onMain { CoilBitmapLoader(context).loadBitmap(Uri.fromFile(file)) }
        val error = assertThrows(ExecutionException::class.java) {
            future.get(10, TimeUnit.SECONDS)
        }

        assertTrue(error.cause is IOException)
    }

    @Test
    fun pendingArtworkFuturesCanBeCanceled() {
        val future = onMain {
            CoilBitmapLoader(context).decodeBitmap(createImageBytes()).also {
                assertTrue(it.cancel(false))
            }
        }

        assertTrue(future.isCancelled)
        assertThrows(CancellationException::class.java) {
            future.get(10, TimeUnit.SECONDS)
        }
    }

    private fun createImageBytes(): ByteArray {
        val bitmap = Bitmap.createBitmap(16, 8, Bitmap.Config.ARGB_8888)
        try {
            return ByteArrayOutputStream().use { output ->
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
                output.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun <T> onMain(action: () -> T): T {
        val task = FutureTask(action)
        instrumentation.runOnMainSync(task)
        return task.get(10, TimeUnit.SECONDS)
    }
}
