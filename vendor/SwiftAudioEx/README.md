# SwiftAudioEx

The vendored pod is based on [DoubleSymmetry/SwiftAudioEx 1.1.0](https://github.com/DoubleSymmetry/SwiftAudioEx/tree/7b506bebabd68b542256c0e1e55519fab5f4c092) and uses the included MIT license. This fork keeps the `SwiftAudioEx` pod and module names and uses CocoaPods version `1.1.0-yrt.1`.

The local `AVPlayerWrapper.load()` guard also recreates an `AVPlayer` whose status is `.failed`. This preserves the existing playback recovery after `stop()` or `unload()` changes the wrapper state. The fix previously ran as a CocoaPods post-install source rewrite.

The wrapper retires the current asset before cancelling its loads. Optional metadata reads and eager item snapshots run on a private worker queue after their keys load. Common, chapter, and timed metadata retain their existing delegate payloads and order. Delivery runs on main and checks asset identity before every event, including after a delegate replaces the track. Live timed metadata uses the same snapshot preparation and preserves every batch in arrival order. Retiring an asset discards its queued batches without changing the replacement asset's queue. Playable loading remains independent, and duration reads use the asset only when its duration key is loaded before falling back to the player item and live seekable range. These changes retain the pod's iOS 11 minimum and existing public API.

RNTP requires the fork version for the main-queue listener, artwork loader, and seek-position APIs. The app and the example already select the vendored pod in their Podfiles. To install this RNTP fork in another app, add this dependency to the iOS app target in its Podfile and run `pod install`.

```ruby
pod 'SwiftAudioEx', :path => '../node_modules/react-native-track-player/vendor/SwiftAudioEx'
```

Adjust the path if your package manager installs RNTP in a different directory.

Run `npm run test:native:swift` from the app repository root to test metadata cancellation, stale delivery, eager values, duration, deferred seeking, the recovery guard, and RNTP playback utilities. Run `npm run test:native:swift:ios` for the same wrapper tests and RNTP iOS integration tests. Both runners accept `--swift-audio-source-root` for comparison with another source tree. The macOS runner also accepts `--test-filter CLASS/METHOD` to select a regression.

The single-item insertion correction comes from upstream commit [`a574f94c6ba84b7c97f5fdadf31c69503b12dad6`](https://github.com/DoubleSymmetry/SwiftAudioEx/commit/a574f94c6ba84b7c97f5fdadf31c69503b12dad6), which follows the 1.1.0 tag. Local queue fixes preserve the active item during moves and insertions, release locks after errors, and deliver delegate callbacks after unlocking.

Playback operations reject retired item callbacks and seeks. Repeat playback waits for seek completion and respects newer commands. Artwork publication checks the current request and automatic metadata setting. Item status observation reports failures once, external pauses update the playback state, and failed-player recreation preserves playback settings. The native regression suites cover these behaviors alongside the existing metadata and recovery cases.

Both test runners accept repeated `--test-file NAME` selections and `--test-filter CLASS/METHOD` for focused regression runs. The macOS runner includes the queue and wrapper suites. Player, artwork, and RNTP integration tests run on the iOS simulator.

The synchronous load-failure autoplay guard also follows [upstream main at `42767039`](https://github.com/DoubleSymmetry/SwiftAudioEx/blob/42767039eb8e2a3caef81e39d4c66de26d6b9944/Sources/SwiftAudioEx/AudioPlayer.swift). Invalid sources retire the previous URL, so retry cannot play an older track. Transport observations follow explicit play/pause intent, while track-end observations follow source and seek position. Manual metadata refresh remains available when automatic updates are disabled.

For comparisons, `--swift-audio-source-root PATH` selects preserved production sources and `--swift-audio-test-root PATH` selects preserved test sources. Runners fail if the selection executes no tests. The macOS runner reuses its generated compiler cache under `web/tmp/native-playback-tests/`; simulator tests have bounded execution timeouts.

Toggling during loading follows playback intent. Unload retires the stored source before callbacks, while stop retains it for a later restart. External pause handling uses the item endpoint rather than a live seekable window's length.

Initial and replay seeks hold native playback until their owned completion. Cancelling an older seek does not change a newer seek's playback intent. `pendingSeekPosition` identifies an active request. `recoveryPosition` also retains a failed resume target for the same source, so retry and RNTP media-services recovery share one position owner. Stop, source replacement, and a newer seek discard that failed target. Manual-wait buffering recovery respects interruption and route permission, current source identity, and newer transport commands.

The original `seek(to:)` and `loadNowPlayingMetaValues()` declarations remain available, including as method references. Seeking with a completion handler uses a separate overload. Clearing the queue retains `playWhenReady`, so RNTP queue replacement preserves playing or paused intent. RNTP reset explicitly stops before clearing.

Queue, wrapper, and observer regressions run on macOS. The iOS suite also covers player events, artwork and partial metadata updates, real interruption notifications, native recovery positions, and lock-screen metadata. RNTP opts source-owned event listeners into main delivery so an ended or failed event cannot be attributed to a replacement track; default public listeners remain asynchronous.
