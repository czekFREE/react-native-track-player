package com.doublesymmetry.trackplayer.service

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.os.Looper
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import androidx.media3.common.Player
import com.doublesymmetry.trackplayer.model.Capability
import androidx.media3.exoplayer.ExoPlayer
import com.doublesymmetry.trackplayer.HeadlessJsMediaService
import com.doublesymmetry.trackplayer.model.Track
import com.facebook.react.bridge.ReactContext
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], shadows = [MusicServiceLifecycleTest.NoReactRuntime::class, MusicServiceLifecycleTest.NoReactEvents::class])
@LooperMode(LooperMode.Mode.PAUSED)
class MusicServiceLifecycleTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        val launcher = ComponentName(context.packageName, "FixtureActivity")
        val packageManager = shadowOf(context.packageManager)
        packageManager.addActivityIfNotPresent(launcher)
        packageManager.addIntentFilterForActivity(launcher, IntentFilter(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        })
    }

    @Test
    fun destructionBeforeSetupReleasesTheStartupSessionAndRejectsBinding() {
        val lifecycle = Robolectric.buildService(MusicService::class.java).create()
        val service = lifecycle.get()
        val session = service.onGetSession(controllerInfo())
        val startupPlayer = session.player as ExoPlayer
        lifecycle.destroy()
        service.onDestroy()
        assertTrue(startupPlayer.isReleased)
        assertNull(service.onBind(Intent(context, MusicService::class.java)))
        Robolectric.buildService(MusicService::class.java).create().destroy()
    }

    @Test
    fun setupTwiceKeepsTheExistingQueueAndSessionPlayer() {
        val lifecycle = Robolectric.buildService(MusicService::class.java).create()
        val service = lifecycle.get()
        try {
            val session = service.onGetSession(controllerInfo())
            val startupPlayer = session.player as ExoPlayer
            service.setupPlayer(null)
            val configuredPlayer = session.player
            assertNotSame(startupPlayer, configuredPlayer)
            assertTrue(startupPlayer.isReleased)
            val track = Track(context, Bundle().apply {
                putString("url", "https://example.invalid/fixture.mp3")
                putString("mediaId", "episode")
            }, 0)
            service.add(track)
            service.setupPlayer(Bundle().apply { putDouble("maxCacheSize", 64.0) })
            assertSame(configuredPlayer, session.player)
            assertSame(track, service.currentTrack)
            assertEquals(listOf(track), service.tracks)
        } finally { lifecycle.destroy() }
    }

    @Test
    fun appBindingAndRebindingUseTheSameServiceInstanceAndReleaseCleanly() {
        val lifecycle = Robolectric.buildService(MusicService::class.java).create()
        val service = lifecycle.get()
        val intent = Intent(context, MusicService::class.java)
        try {
            service.setupPlayer(null)
            val first = service.onBind(intent)
            assertTrue(first is MusicService.MusicBinder)
            assertSame(service, (first as MusicService.MusicBinder).service)
            service.onUnbind(intent)
            assertSame(first, service.onBind(intent))
        } finally { lifecycle.destroy() }
        shadowOf(Looper.getMainLooper()).idle()
        assertNull(service.onBind(intent))
    }

    @Test
    fun ordinaryAndNotificationConnectionsKeepQueueMutationCommandsUnavailable() {
        val lifecycle = Robolectric.buildService(MusicService::class.java).create()
        val service = lifecycle.get()
        val session = service.onGetSession(controllerInfo())
        val connections = listOf(
            MediaController.Builder(context, session.token).buildAsync(),
            MediaController.Builder(context, session.token)
                .setConnectionHints(Bundle().apply {
                    putBoolean("androidx.media3.session.MediaNotificationManager", true)
                }).buildAsync(),
        )
        try {
            service.setupPlayer(null)
            shadowOf(Looper.getMainLooper()).idle()
            val controllers = connections.map { future ->
                assertTrue("Local session connection must complete", future.isDone)
                future.get()
            }
            controllers.forEach { controller ->
                assertEquals(
                    MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS,
                    controller.availableSessionCommands,
                )
                assertFalse(controller.isCommandAvailable(Player.COMMAND_SET_MEDIA_ITEM))
                assertFalse(controller.isCommandAvailable(Player.COMMAND_CHANGE_MEDIA_ITEMS))
            }
            service.updateOptions(Bundle().apply {
                putBundle("android", Bundle())
                putIntegerArrayList("capabilities", arrayListOf(Capability.PLAY.ordinal, Capability.PAUSE.ordinal))
            })
            service.add(Track(context, Bundle().apply {
                putString("url", "https://example.invalid/fixture.mp3")
                putString("mediaId", "episode")
            }, 0))
            shadowOf(Looper.getMainLooper()).idle()
            controllers.forEach { controller ->
                assertTrue(controller.isCommandAvailable(Player.COMMAND_PLAY_PAUSE))
                assertFalse(controller.isCommandAvailable(Player.COMMAND_SET_MEDIA_ITEM))
                assertFalse(controller.isCommandAvailable(Player.COMMAND_CHANGE_MEDIA_ITEMS))
            }
        } finally {
            connections.forEach(MediaController::releaseFuture)
            lifecycle.destroy()
        }
    }

    private fun controllerInfo(): MediaSession.ControllerInfo = MediaSession.ControllerInfo.createTestOnlyControllerInfo(
        "fixture-controller", 0, 0, 0, 0, false, Bundle.EMPTY,
    )

    @Implements(HeadlessJsMediaService::class)
    open class NoReactRuntime : org.robolectric.shadows.ShadowService() {
        @Implementation
        protected fun getReactContext(): ReactContext? = null
    }

    @Implements(MusicService::class)
    class NoReactEvents : NoReactRuntime() {
        @Implementation
        protected fun emit(event: String, data: Bundle?) = Unit
    }
}
