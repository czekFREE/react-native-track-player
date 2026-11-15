# Android playback

RNTP owns its Android playback implementation and uses Media3 directly. KotlinAudio is no longer a build dependency. Media3 remains pinned to 1.8.0.

`MusicService` owns the media session, React Native service integration, notification policy, and progress scheduling. `RNTPPlaybackController` owns the configured ExoPlayer, track associations, playback events, focus policy, and source/cache resources. Media3 owns playlist order. Each inserted track has a separate `QueueEntry` tag, so duplicate public IDs and URLs remain valid.

External media controls pass through `RNTPRemotePlayer` and emit the existing JavaScript remote events. The app retains control over how those commands change playback.

## Intentional corrections

- Backward and equal-index moves now report the same order that Media3 plays. Previously `move(2, 1)` on A, B, C, D played A, C, B, D but reported C, A, B, D. Moving an item to its current index now leaves the queue unchanged.
- Public `type: 'smoothstreaming'` selects the SmoothStreaming source. The old enum-name mismatch selected a progressive source instead.
- Manual audio-focus ducking restores the requested volume after focus returns. The old implementation multiplied an already reduced volume during restoration.

## Runtime dependency ownership

RNTP directly declares the Media3 common, ExoPlayer, session, UI, HLS, DASH, and SmoothStreaming modules at 1.8.0. It also owns the Android coroutine dispatcher used by its service. The removal preserves existing runtime version declarations and resolved app versions. Test dependencies are isolated from the production configuration.

## Dependency update candidates

Stable release versions were checked on November 15, 2026. The YRT column records the app's resolved release dependencies. Declared library pins can resolve to higher versions in the host app. These candidates have not been upgraded in this removal.

| Dependency                                                    | RNTP declaration | YRT release    | Candidate and scope                                                                                                                                                                                                                                       |
| ------------------------------------------------------------- | ---------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Media3 common, ExoPlayer, session, HLS, DASH, SmoothStreaming | 1.8.0            | 1.8.0          | [1.11.1](https://developer.android.com/jetpack/androidx/releases/media3). Upgrade together with RNTP's Media3 dependencies and verify playback, buffering, audio focus, and media controls. The newer release uses Kotlin 2.2.0 and includes API changes. |
| Guava                                                         | 33.0.0-android   | 33.3.1-android | [33.8.0-android](https://github.com/google/guava/releases/tag/v33.8.0). A routine update candidate shared with RNTP.                                                                                                                                      |
| Coroutines core and Android                                   | 1.7.3            | 1.9.0          | [1.11.0](https://github.com/Kotlin/kotlinx.coroutines/releases/tag/1.11.0). Align with RNTP's coroutines-guava and check Kotlin compatibility. Upstream builds with Kotlin 2.2.20.                                                                        |
| AndroidX Core KTX                                             | 1.13.1           | 1.18.0         | [Core 1.19.1](https://developer.android.com/jetpack/androidx/releases/core). Kotlin extensions moved into core, so the core-ktx artifact is now an empty compatibility artifact. Check the host's AndroidX and SDK requirements together.                 |
| Legacy AndroidX Media                                         | 1.7.0            | 1.7.0          | [1.8.0](https://developer.android.com/jetpack/androidx/releases/media). This release deprecates the library. RNTP still uses its audio-focus APIs, and RNTP uses its rating APIs. Removing it requires a code migration.                                  |
| Timber                                                        | 5.0.1            | 5.0.1          | Already at the [latest release](https://github.com/JakeWharton/timber/releases/tag/5.0.1).                                                                                                                                                                |

Native JVM tests use JUnit 4.13.2 and Robolectric 4.18. Device tests use AndroidX Test runner 1.7.0 and JUnit extensions 1.3.0. These are test dependencies. The consuming app owns AGP, Kotlin, Gradle, and SDK settings.

RNTP still owns artwork loading through Coil 2.4.0 and Wasabeef transformations 1.0.6. [Coil 2.7.0](https://github.com/coil-kt/coil/releases/tag/2.7.0) is the smaller upgrade. [Coil 3.6.3](https://github.com/coil-kt/coil/releases/tag/3.6.3) requires the [Coil 3 migration](https://coil-kt.github.io/coil/upgrading_to_coil3/), including the artwork loader and network setup. RNTP's Lifecycle process/runtime dependencies resolve to 2.8.7, with [2.11.0](https://developer.android.com/jetpack/androidx/releases/lifecycle) available after a host compatibility check.

RNTP's activity-compose 1.9.3, Compose UI/graphics 1.6.8, LocalBroadcastManager 1.1.0, and production AndroidX Test rules 1.6.1 remain removal candidates. No source usage was found in the current RNTP Android implementation. They remain unchanged because this removal does not include unrelated dependency cleanup.

## Native verification

From the consuming Youradio Talk `android` directory, run:

```sh
./gradlew :react-native-track-player:testDebugUnitTest :react-native-track-player:testReleaseUnitTest
./gradlew :react-native-track-player:connectedDebugAndroidTest
./gradlew :app:assembleDebug :app:assembleRelease
```

The connected test command requires an Android emulator or device. JVM tests use real Media3 playlists under Robolectric. JavaScript tests cannot verify native SDK behavior. Device UI checks do not verify audible output, physical Bluetooth controls, or calls.

Run the consuming app's native JavaScript suites, TypeScript checks, and lint too. The YRT implementation plan records exact build evidence and a physical-device testing checklist.

## Source attribution

Playback, focus, buffer, and source handling adapt the KotlinAudio implementation from `czekFREE/KotlinAudio` at `0947c839e9eb967815627a45a17d54e4c19eb915`, copyright 2022 Double Symmetry GmbH. Those files have been modified for direct RNTP track/state/event ownership, resource lifetimes, and the corrections above. The retained Apache 2.0 license is in [licenses/KotlinAudio-LICENSE](licenses/KotlinAudio-LICENSE). The remote fork remains available for provenance and rollback.
