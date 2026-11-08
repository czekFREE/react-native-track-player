# SwiftAudioEx

This directory contains [DoubleSymmetry/SwiftAudioEx](https://github.com/DoubleSymmetry/SwiftAudioEx) version 1.1.0 at commit [`7b506bebabd68b542256c0e1e55519fab5f4c092`](https://github.com/DoubleSymmetry/SwiftAudioEx/tree/7b506bebabd68b542256c0e1e55519fab5f4c092), under the included MIT license. The upstream sources and podspec retain the `SwiftAudioEx` module, pod name, version, and API.

The local `AVPlayerWrapper.load()` guard also recreates an `AVPlayer` whose status is `.failed`. This preserves the existing playback recovery after `stop()` or `unload()` changes the wrapper state. The fix previously ran as a CocoaPods post-install source rewrite.

The app's `ios/Podfile` selects this local pod. `react-native-track-player.podspec` continues to depend on `SwiftAudioEx` version 1.1.0.

Run `npm run test:native:swift` from the app repository root to test the recovery guard and RNTP playback utilities. Run `npm run test:native:swift:ios` for the RNTP iOS integration tests. Both runners accept `--swift-audio-source-root` for comparison with another source tree.
