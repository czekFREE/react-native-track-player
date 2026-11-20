# Android playback

RNTP owns its Android playback implementation and uses Media3 directly. KotlinAudio is no longer a build dependency. Media3 is pinned to 1.11.1.

`MusicService` owns the media session, React Native service integration, notification policy, and progress scheduling. `RNTPPlaybackController` owns the configured ExoPlayer, track associations, playback events, focus policy, and source/cache resources. Media3 owns playlist order. Each inserted track has a separate `QueueEntry` tag, so duplicate public IDs and URLs remain valid.

External media controls pass through `RNTPRemotePlayer` and emit the existing JavaScript remote events. The app retains control over how those commands change playback.

Player setup explicitly starts the headless JavaScript playback task. The native service starts that task once per service instance and reuses it for later Android start commands. This keeps initial playback listeners independent of Media3 notification and controller timing.

## Intentional corrections

- Backward and equal-index moves now report the same order that Media3 plays. Previously `move(2, 1)` on A, B, C, D played A, C, B, D but reported C, A, B, D. Moving an item to its current index now leaves the queue unchanged.
- Public `type: 'smoothstreaming'` selects the SmoothStreaming source. The old enum-name mismatch selected a progressive source instead.
- Manual audio-focus ducking restores the requested volume after focus returns. The old implementation multiplied an already reduced volume during restoration.

## Runtime dependency ownership

RNTP directly declares the Media3 common, ExoPlayer, session, UI, HLS, DASH, and SmoothStreaming modules. Production modules and test utilities share one `media3Version` in `build.gradle`. The coroutine core, Android dispatcher, and Guava bridge share one `coroutinesVersion`.

| Dependency                                   | RNTP declaration | Purpose                                                            |
| -------------------------------------------- | ---------------- | ------------------------------------------------------------------ |
| Media3 production modules and test utilities | 1.11.1           | Playback, media sessions, source handling, and native test support |
| Guava Android                                | 33.8.0-android   | Session futures and immutable collections; requires Android API 24 |
| Coroutines core, Android, and Guava bridge   | 1.10.2           | Service jobs, progress scheduling, and artwork futures             |
| Coil 2                                       | 2.7.0            | Notification and controller artwork loading                        |
| Wasabeef Coil transformations                | 1.0.6            | Square artwork cropping, including the Samsung policy              |
| AndroidX Media compatibility                 | 1.7.0            | Audio-focus compatibility, rating conversion, and media constants  |
| AndroidX Lifecycle process and runtime       | 2.8.6            | Application foreground tracking and lifecycle support              |
| AndroidX Core KTX                            | 1.13.1           | Android compatibility helpers                                      |
| Timber                                       | 5.0.1            | Logging boundary                                                   |

The consuming application can resolve higher shared versions. For example, YRT resolves Core 1.18.0 and Lifecycle 2.8.7. Coil 3, broad AndroidX updates, and migration away from legacy Media remain separate work.

Unused Activity Compose, Compose UI/graphics, LocalBroadcastManager, and production AndroidX Test rules declarations have been removed from RNTP. YRT owns constraints for Activity, Activity KTX, and LocalBroadcastManager to preserve the versions its other SDKs already used. Other application dependencies still bring Compose UI and LocalBroadcastManager into the app.

Native JVM tests use JUnit 4.13.2 and Robolectric 4.18. Device tests use AndroidX Test runner 1.7.0 and JUnit extensions 1.3.0. These dependencies stay in test configurations.

## Android build requirements

The Media3 1.11.1 AAR metadata requires compile SDK 36. RNTP's fallback settings use compile SDK 36, minimum SDK 24, Kotlin 2.1.20, and AGP 8.12.0. YRT already uses these compiler and plugin versions, so the dependency update keeps its host toolchain unchanged. The root project's SDK and Kotlin extension properties override the corresponding RNTP fallback properties.

The library's fallback target SDK remains 34. YRT owns its application target SDK, currently 36. Keep compile SDK requirements separate from application target-SDK behavior.

## Update boundaries

Upgrade all retained Media3 artifacts together, including `media3-test-utils`. Compare the consuming app's resolved graph and inspect published AAR requirements before raising versions. Updating a dependency declaration can change the versions selected for other native modules.

Preserve RNTP's configured audio-focus owner, wake mode, buffers, offload policy, and JavaScript remote-command routing during dependency updates. The generic buffer setter configures both local files and streams. RNTP explicitly sets its wake mode, so a newer ExoPlayer builder default does not change that setting automatically. New Media3 stuck-player errors use the existing playback-error flow.

## Native verification

From the consuming Youradio Talk `android` directory, run:

```sh
./gradlew :react-native-track-player:testDebugUnitTest :react-native-track-player:testReleaseUnitTest
./gradlew :react-native-track-player:connectedDebugAndroidTest
./gradlew :app:assembleDebug :app:assembleRelease
```

The connected test command requires an Android emulator or device. JVM tests use real Media3 playlists under Robolectric. Buffer assertions cover streams and local files on API 24 and 28. JavaScript tests cannot verify native SDK behavior. Instrumentation also checks bitmap decoding, file artwork, square cropping, I/O failures, and coroutine-future cancellation. Device UI checks do not verify audible output, physical Bluetooth controls, or calls.

Run the consuming app's native JavaScript suites, TypeScript checks, and lint too. The YRT implementation plan records exact build evidence and a physical-device testing checklist.

## Source attribution

Playback, focus, buffer, and source handling adapt the KotlinAudio implementation from `czekFREE/KotlinAudio` at `0947c839e9eb967815627a45a17d54e4c19eb915`, copyright 2022 Double Symmetry GmbH. Those files have been modified for direct RNTP track/state/event ownership, resource lifetimes, and the corrections above. The retained Apache 2.0 license is in [licenses/KotlinAudio-LICENSE](licenses/KotlinAudio-LICENSE). The remote fork remains available for provenance and rollback.
