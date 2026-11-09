# SwiftAudioEx

This directory contains [DoubleSymmetry/SwiftAudioEx](https://github.com/DoubleSymmetry/SwiftAudioEx) version 1.1.0 at commit [`7b506bebabd68b542256c0e1e55519fab5f4c092`](https://github.com/DoubleSymmetry/SwiftAudioEx/tree/7b506bebabd68b542256c0e1e55519fab5f4c092), under the included MIT license. The upstream sources and podspec retain the `SwiftAudioEx` module, pod name, version, and API.

The local `AVPlayerWrapper.load()` guard also recreates an `AVPlayer` whose status is `.failed`. This preserves the existing playback recovery after `stop()` or `unload()` changes the wrapper state. The fix previously ran as a CocoaPods post-install source rewrite.

The wrapper retires the current asset before cancelling its loads. Optional metadata reads and eager item snapshots run on a private worker queue after their keys load. Common, chapter, and timed metadata retain their existing delegate payloads and order. Delivery runs on main and checks asset identity before every event, including after a delegate replaces the track. Live timed metadata uses the same snapshot preparation and preserves every batch in arrival order. Retiring an asset discards its queued batches without changing the replacement asset's queue. Playable loading remains independent, and duration reads use the asset only when its duration key is loaded before falling back to the player item and live seekable range. These changes retain the pod's iOS 11 minimum and existing public API.

The app's `ios/Podfile` selects this local pod. `react-native-track-player.podspec` continues to depend on `SwiftAudioEx` version 1.1.0.

Run `npm run test:native:swift` from the app repository root to test metadata cancellation, stale delivery, eager values, duration, deferred seeking, the recovery guard, and RNTP playback utilities. Run `npm run test:native:swift:ios` for the same wrapper tests and RNTP iOS integration tests. Both runners accept `--swift-audio-source-root` for comparison with another source tree. The macOS runner also accepts `--test-filter CLASS/METHOD` to select a regression.
