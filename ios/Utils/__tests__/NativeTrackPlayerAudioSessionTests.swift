import AVFoundation
import MediaPlayer
import UIKit
import XCTest

private final class RecordedNativeEvents: NSObject, NativeTrackPlayerImplDelegate {
  struct Entry {
    let name: String
    let body: [String: Any]
  }

  private let lock = NSLock()
  private var entries: [Entry] = []

  var events: [Entry] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }

  func sendEvent(name: String, body: Any) {
    lock.lock()
    defer { lock.unlock() }
    entries.append(Entry(name: name, body: body as? [String: Any] ?? [:]))
  }
}

private struct NativeBridgeOutcome {
  var resolved = false
  var errorCode: String?
  var errorMessage: String?
}

private func invokeNativeBridge(
  _ action: (_ resolve: @escaping RCTPromiseResolveBlock, _ reject: @escaping RCTPromiseRejectBlock)
    -> Void
) -> NativeBridgeOutcome {
  var outcome = NativeBridgeOutcome()
  action(
    { _ in outcome.resolved = true },
    { code, message, _ in
      outcome.errorCode = code
      outcome.errorMessage = message
    })
  return outcome
}

private func writeLocalAudioFixture() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "native-recovery-\(UUID().uuidString).wav")
  let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
  let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
  buffer.frameLength = buffer.frameCapacity
  let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
  samples.initialize(repeating: 0, count: Int(buffer.frameCapacity))
  let file = try AVAudioFile(forWriting: url, settings: format.settings)
  try file.write(from: buffer)
  return url
}

private func waitForNativeCondition(_ description: String, _ condition: @escaping () -> Bool) {
  let predicate = NSPredicate { _, _ in condition() }
  let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
  expectation.expectationDescription = description
  XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, description)
}

#if NATIVE_AUDIO_RECOVERY_BASELINE
  final class NativeTrackPlayerAudioSessionBaselineTests: XCTestCase {
    func testMediaServicesResetPausesPlaybackAndReportsRecovery() throws {
      let native = NativeTrackPlayerImpl()
      let recorder = RecordedNativeEvents()
      native.delegate = recorder
      let audioURL = try writeLocalAudioFixture()
      defer {
        _ = invokeNativeBridge { native.reset(resolve: $0, reject: $1) }
        try? FileManager.default.removeItem(at: audioURL)
      }
      XCTAssertTrue(
        invokeNativeBridge { native.setupPlayer(config: [:], resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(
        invokeNativeBridge {
          native.load(
            trackDict: ["id": "baseline-track", "url": audioURL.absoluteString], resolve: $0,
            reject: $1)
        }.resolved)
      XCTAssertTrue(invokeNativeBridge { native.play(resolve: $0, reject: $1) }.resolved)
      NotificationCenter.default.post(
        name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
      var playWhenReady: Bool?
      native.getPlayWhenReady(
        resolve: { playWhenReady = $0 as? Bool },
        reject: { _, _, _ in XCTFail("State read failed") })
      XCTAssertEqual(
        playWhenReady, false, "A media-services reset must discard the previous playback intention")
      XCTAssertTrue(
        recorder.events.contains {
          $0.name == "playback-state" && $0.body["state"] as? String == "paused"
        }, "The bridge must tell the application that playback paused after media-services reset")
    }
  }
#else
  private final class SessionBoundary {
    var activationAttempts = 0
    var deactivationAttempts = 0
    var configuredCategories: [AVAudioSession.Category] = []
    var failActivations = 0
    var failConfiguration = false

    func configure(
      category: AVAudioSession.Category,
      mode: AVAudioSession.Mode,
      policy: AVAudioSession.RouteSharingPolicy,
      options: AVAudioSession.CategoryOptions
    ) throws {
      configuredCategories.append(category)
      if failConfiguration {
        throw NSError(
          domain: "NativeAudioSessionTest", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Session category rejected"])
      }
    }

    func activate() throws {
      activationAttempts += 1
      if failActivations > 0 {
        failActivations -= 1
        throw NSError(
          domain: "NativeAudioSessionTest", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Session activation rejected"])
      }
    }
  }

  private final class TestNowPlayingInfoCenter: NowPlayingInfoCenter {
    var nowPlayingInfo: [String: Any]?
  }

  private final class DeferredArtworkTrack: Track {
    private(set) var artworkRequestCount = 0
    private var handlers: [(UIImage?) -> Void] = []

    override func getArtwork(_ handler: @escaping (UIImage?) -> Void) {
      artworkRequestCount += 1
      handlers.append(handler)
    }

    func finishArtworkRequests(image: UIImage?) {
      let pendingHandlers = handlers
      handlers = []
      pendingHandlers.forEach { $0(image) }
    }
  }

  private final class NativeSessionFixture {
    let notificationCenter = NotificationCenter()
    let session = SessionBoundary()
    let recorder = RecordedNativeEvents()
    let infoCenter = TestNowPlayingInfoCenter()
    private(set) var generations: [PlaybackOwnerGeneration] = []
    private(set) var owners: [QueuedAudioPlayer] = []
    private(set) var native: NativeTrackPlayerImpl?
    let audioURL: URL

    init() throws {
      audioURL = try writeLocalAudioFixture()
      native = NativeTrackPlayerImpl(
        playerFactory: { [unowned self] generation in
          let center = GenerationScopedNowPlayingInfoCenter(
            generation: generation, center: self.infoCenter)
          let owner = QueuedAudioPlayer(
            nowPlayingInfoController: NowPlayingInfoController(infoCenter: center))
          self.generations.append(generation)
          self.owners.append(owner)
          return owner
        },
        notificationCenter: notificationCenter,
        configureSession: session.configure,
        activateSession: session.activate,
        deactivateSession: { [session] in session.deactivationAttempts += 1 }
      )
      native?.delegate = recorder
    }

    func setUp(config: [String: Any] = [:], options: [String: Any] = [:]) throws
      -> NativeTrackPlayerImpl
    {
      let native = try XCTUnwrap(native)
      XCTAssertTrue(
        invokeNativeBridge { native.setupPlayer(config: config, resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.update(options: options, resolve: $0, reject: $1) }.resolved)
      return native
    }

    func tracks() -> [[String: Any]] {
      [
        ["id": "first-track", "title": "First track", "url": audioURL.absoluteString],
        ["id": "second-track", "title": "Second track", "url": audioURL.absoluteString],
      ]
    }

    func postMediaServicesReset() {
      notificationCenter.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    deinit {
      if let native = native {
        _ = invokeNativeBridge { native.reset(resolve: $0, reject: $1) }
      }
      try? FileManager.default.removeItem(at: audioURL)
    }
  }

  final class NativeTrackPlayerAudioSessionTests: XCTestCase {
    func testLateProgressEventForPreviousTrackDoesNotChangeReplacementTrackPosition() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition("The first track is loaded before the delayed progress event") {
        native.player.playerState == .ready
      }
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[1], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition(
        "The replacement track is at its beginning before the delayed progress event"
      ) { native.player.playerState == .ready }
      XCTAssertEqual(native.player.currentTime, 0, accuracy: 0.1)
      let lateProgressProcessed = expectation(
        description: "A late progress event from the prior track is delivered")
      native.player.event.secondElapse.addListener(self) { seconds in
        if seconds == 9 { DispatchQueue.main.async { lateProgressProcessed.fulfill() } }
      }
      native.player.event.secondElapse.emit(data: 9)
      wait(for: [lateProgressProcessed], timeout: 5)
      native.player.event.secondElapse.removeListener(self)

      fixture.postMediaServicesReset()

      let restoredSeek = expectation(
        description: "The replacement owner restores the current track's timeline")
      native.player.event.seek.addListener(self) { event in
        if event.didFinish { DispatchQueue.main.async { restoredSeek.fulfill() } }
      }
      wait(for: [restoredSeek], timeout: 5)
      XCTAssertEqual(
        (native.player.currentItem as? Track)?.toObject()["id"] as? String, "second-track")
      XCTAssertEqual(
        native.player.currentTime, 0, accuracy: 0.1,
        "An old track's progress event must not become the replacement track's recovery position")
    }

    func testLateSeekCompletionForPreviousTrackDoesNotChangeReplacementTrackPosition() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition("The first track is loaded") { native.player.playerState == .ready }
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[1], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition("The replacement track is loaded at its beginning") {
        native.player.playerState == .ready
      }
      XCTAssertEqual(native.player.currentTime, 0, accuracy: 0.1)
      let lateSeekProcessed = expectation(
        description: "A late seek completion from the prior track is delivered")
      native.player.event.seek.addListener(self) { _ in
        DispatchQueue.main.async { lateSeekProcessed.fulfill() }
      }
      native.player.event.seek.emit(data: (seconds: 9, didFinish: true))
      wait(for: [lateSeekProcessed], timeout: 5)
      native.player.event.seek.removeListener(self)

      fixture.postMediaServicesReset()

      let restoredSeek = expectation(
        description: "The replacement native owner restores its retained timeline")
      native.player.event.seek.addListener(self) { event in
        if event.didFinish { DispatchQueue.main.async { restoredSeek.fulfill() } }
      }
      wait(for: [restoredSeek], timeout: 5)
      XCTAssertEqual(
        (native.player.currentItem as? Track)?.toObject()["id"] as? String, "second-track")
      XCTAssertEqual(
        native.player.currentTime, 0, accuracy: 0.1,
        "An old track's completed seek must not become the replacement track's recovery position")
    }

    func testResetRequestsArtworkOnlyForTheRetainedActiveTrackWhenAutomaticMetadataIsEnabled()
      throws
    {
      for automaticMetadata in [true, false] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp(config: ["autoUpdateMetadata": automaticMetadata])
        let firstTrack = try XCTUnwrap(DeferredArtworkTrack(dictionary: fixture.tracks()[0]))
        let selectedTrack = try XCTUnwrap(DeferredArtworkTrack(dictionary: fixture.tracks()[1]))
        defer {
          firstTrack.finishArtworkRequests(image: nil)
          selectedTrack.finishArtworkRequests(image: nil)
        }
        native.player.add(items: [firstTrack, selectedTrack], playWhenReady: false)
        XCTAssertTrue(
          invokeNativeBridge { native.skip(to: 1, initialTime: -1, resolve: $0, reject: $1) }
            .resolved)
        let firstTrackRequests = firstTrack.artworkRequestCount
        let selectedTrackRequests = selectedTrack.artworkRequestCount
        XCTAssertEqual(firstTrackRequests, automaticMetadata ? 1 : 0)
        XCTAssertEqual(selectedTrackRequests, automaticMetadata ? 1 : 0)

        fixture.postMediaServicesReset()

        XCTAssertEqual(native.player.currentIndex, 1)
        XCTAssertEqual(native.player.automaticallyUpdateNowPlayingInfo, automaticMetadata)
        XCTAssertEqual(firstTrack.artworkRequestCount, firstTrackRequests)
        XCTAssertEqual(
          selectedTrack.artworkRequestCount, selectedTrackRequests + (automaticMetadata ? 1 : 0))
        if automaticMetadata {
          let selectedImage = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image {
            context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
          }
          firstTrack.finishArtworkRequests(image: nil)
          selectedTrack.finishArtworkRequests(image: selectedImage)
          waitForNativeCondition(
            "Only the retained track publishes artwork on the new native owner"
          ) {
            let artwork =
              fixture.infoCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
            return artwork?.image(at: selectedImage.size) === selectedImage
          }
        }
      }
    }

    func testResetPreservesZeroBufferWithAutomaticWaitingExplicitlyDisabled() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      native.player.automaticallyWaitsToMinimizeStalling = false
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition("The zero-buffer item is ready before reset") {
        native.player.playerState == .ready
      }
      XCTAssertEqual(native.player.bufferDuration, 0)
      XCTAssertFalse(native.player.automaticallyWaitsToMinimizeStalling)
      fixture.postMediaServicesReset()
      XCTAssertEqual(native.player.bufferDuration, 0)
      XCTAssertFalse(native.player.automaticallyWaitsToMinimizeStalling)
      XCTAssertFalse(native.player.playWhenReady)
    }

    func testResetBeforeSetupDiscardsTheNativeOwnerWithoutEmittingPlaybackOrActivating() throws {
      let fixture = try NativeSessionFixture()
      let native = try XCTUnwrap(fixture.native)
      let oldOwner = native.player
      fixture.postMediaServicesReset()
      XCTAssertFalse(native.player === oldOwner)
      XCTAssertEqual(fixture.owners.count, 2)
      XCTAssertEqual(fixture.recorder.events.count, 0)
      XCTAssertEqual(fixture.session.activationAttempts, 0)
      XCTAssertTrue(
        invokeNativeBridge { native.setupPlayer(config: [:], resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      XCTAssertEqual(fixture.session.activationAttempts, 1)
    }

    func testRepeatedResetsPreserveAPendingSeekWithoutActivating() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 8, resolve: $0, reject: $1) }.resolved)
      fixture.postMediaServicesReset()
      fixture.postMediaServicesReset()
      XCTAssertEqual(fixture.owners.count, 3)
      XCTAssertEqual(fixture.session.activationAttempts, 0)
      XCTAssertFalse(native.player.playWhenReady)
      waitForNativeCondition("Repeated resets preserve the pending seek on the final native owner")
      {
        abs(native.player.currentTime - 8) < 0.3
      }
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("Explicit Play advances beyond the restored seek") {
        native.player.playerState == .playing && native.player.currentTime > 8
      }
    }

    func testPlayEnqueuedBeforeResetCannotActivateTheReplacementOwner() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      let enqueued = DispatchSemaphore(value: 0)
      let completed = expectation(description: "The pre-reset Play request completes")
      var outcome = NativeBridgeOutcome()
      DispatchQueue.global().async {
        native.play(
          userInitiated: true,
          resolve: { _ in
            outcome.resolved = true
            completed.fulfill()
          },
          reject: { code, message, _ in
            outcome.errorCode = code
            outcome.errorMessage = message
            completed.fulfill()
          })
        enqueued.signal()
      }
      XCTAssertEqual(enqueued.wait(timeout: .now() + 5), .success)
      fixture.postMediaServicesReset()
      wait(for: [completed], timeout: 5)
      XCTAssertFalse(outcome.resolved)
      XCTAssertEqual(outcome.errorCode, "ios_audio_session_requires_explicit_play")
      XCTAssertEqual(fixture.session.activationAttempts, 0)
      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      XCTAssertEqual(fixture.session.activationAttempts, 1)
    }

    func testSetPlayWhenReadyEnqueuedBeforeResetCannotActivateTheReplacementOwner() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      let enqueued = DispatchSemaphore(value: 0)
      let completed = expectation(description: "The pre-reset playWhenReady request completes")
      var outcome = NativeBridgeOutcome()
      DispatchQueue.global().async {
        native.setPlayWhenReady(
          playWhenReady: true,
          resolve: { _ in
            outcome.resolved = true
            completed.fulfill()
          },
          reject: { code, message, _ in
            outcome.errorCode = code
            outcome.errorMessage = message
            completed.fulfill()
          })
        enqueued.signal()
      }
      XCTAssertEqual(enqueued.wait(timeout: .now() + 5), .success)
      fixture.postMediaServicesReset()
      wait(for: [completed], timeout: 5)
      XCTAssertFalse(outcome.resolved)
      XCTAssertEqual(outcome.errorCode, "ios_audio_session_requires_explicit_play")
      XCTAssertEqual(fixture.session.activationAttempts, 0)
      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertTrue(
        invokeNativeBridge { native.setPlayWhenReady(playWhenReady: true, resolve: $0, reject: $1) }
          .resolved)
      XCTAssertEqual(fixture.session.activationAttempts, 1)
    }

    func testAutomaticActivationFailureReportsStructuredErrorWithTrackIdentity() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition(
        "The local asset is ready before injecting observer activation failure"
      ) {
        native.player.playerState == .ready
      }
      fixture.session.failActivations = 1
      native.player.playWhenReady = true
      waitForNativeCondition("The automatic activation failure reaches the native error boundary") {
        fixture.recorder.events.contains {
          $0.name == "playback-error"
            && $0.body["code"] as? String == "audio_session_activation_failed"
        }
      }
      let reported = try XCTUnwrap(fixture.recorder.events.last { $0.name == "playback-error" })
      XCTAssertEqual(reported.body["message"] as? String, "Session activation rejected")
      XCTAssertEqual(reported.body["trackId"] as? String, "first-track")
      XCTAssertFalse(native.player.playWhenReady)
      waitForNativeCondition("The failed automatic attempt reports false playback intention") {
        fixture.recorder.events.contains {
          $0.name == "playback-play-when-ready-changed"
            && $0.body["playWhenReady"] as? Bool == false
        }
      }
      XCTAssertFalse(
        fixture.recorder.events.contains {
          $0.name == "playback-play-when-ready-changed" && $0.body["playWhenReady"] as? Bool == true
        })
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(native.player.playWhenReady)
    }

    func testExplicitPlayRejectsActivationFailureThenRetriesAlreadyRequestedPlayback() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      let requestedPlayback = expectation(description: "The initial play intention is processed")
      native.player.event.playWhenReadyChange.addListener(self) { ready in
        if ready { DispatchQueue.main.async { requestedPlayback.fulfill() } }
      }
      native.player.playWhenReady = true
      wait(for: [requestedPlayback], timeout: 5)
      native.player.event.playWhenReadyChange.removeListener(self)
      fixture.session.failActivations = 1
      let previousAttempts = fixture.session.activationAttempts
      let failed = invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }
      XCTAssertFalse(failed.resolved)
      XCTAssertEqual(failed.errorCode, "audio_session_activation_failed")
      XCTAssertEqual(failed.errorMessage, "Session activation rejected")
      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(fixture.session.activationAttempts, previousAttempts + 1)

      let retried = invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }
      XCTAssertTrue(retried.resolved)
      XCTAssertNil(retried.errorCode)
      XCTAssertEqual(fixture.session.activationAttempts, previousAttempts + 2)
      waitForNativeCondition("Explicit retry plays the real local AVPlayer item") {
        native.player.playerState == .playing && native.player.currentTime > 0
      }
    }

    func testConfigurationFailureStopsPlaybackAndNextExplicitPlayReconfiguresBeforeActivation()
      throws
    {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(config: ["iosCategory": "playback"])
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      fixture.session.failConfiguration = true
      let previousAttempts = fixture.session.activationAttempts
      let failed = invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }
      XCTAssertFalse(failed.resolved)
      XCTAssertEqual(failed.errorCode, "audio_session_configuration_failed")
      XCTAssertEqual(fixture.session.activationAttempts, previousAttempts)
      XCTAssertFalse(native.player.playWhenReady)

      fixture.session.failConfiguration = false
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      XCTAssertEqual(fixture.session.configuredCategories.last, .playback)
      XCTAssertEqual(fixture.session.activationAttempts, previousAttempts + 1)
    }

    func testMediaServicesResetRebuildsRealNativeOwnerAndRestoresQueuePositionAndSettingsPaused()
      throws
    {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(
        config: [
          "iosCategory": "playback", "minBuffer": 3.0, "autoUpdateMetadata": false,
          "autoHandleInterruptions": true,
        ],
        options: [
          "capabilities": ["play", "pause", "next", "previous"],
          "progressUpdateEventInterval": 0.25,
        ]
      )
      XCTAssertTrue(
        invokeNativeBridge {
          native.setQueue(trackDicts: fixture.tracks(), resolve: $0, reject: $1)
        }.resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.skip(to: 1, initialTime: -1, resolve: $0, reject: $1) }.resolved
      )
      XCTAssertTrue(
        invokeNativeBridge { native.setRate(rate: 1.25, resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.setVolume(level: 0.4, resolve: $0, reject: $1) }.resolved)
      native.player.isMuted = true
      native.player.repeatMode = .queue
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The local audio is ready for a meaningful seek") {
        native.player.playerState == .playing
      }
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 4, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The requested native position is applied") {
        native.player.currentTime >= 4
      }
      let oldOwner = native.player
      let position = oldOwner.currentTime
      XCTAssertEqual(oldOwner.bufferDuration, 3)
      XCTAssertFalse(oldOwner.automaticallyWaitsToMinimizeStalling)
      let previousActivations = fixture.session.activationAttempts

      fixture.postMediaServicesReset()

      XCTAssertFalse(native.player === oldOwner)
      XCTAssertEqual(fixture.owners.count, 2)
      XCTAssertEqual(
        native.player.items.compactMap { ($0 as? Track)?.toObject()["id"] as? String },
        ["first-track", "second-track"])
      XCTAssertEqual(native.player.currentIndex, 1)
      XCTAssertEqual(native.player.rate, 1.25)
      XCTAssertEqual(native.player.volume, 0.4)
      XCTAssertTrue(native.player.isMuted)
      XCTAssertEqual(native.player.repeatMode, .queue)
      XCTAssertEqual(native.player.bufferDuration, 3)
      XCTAssertFalse(native.player.automaticallyWaitsToMinimizeStalling)
      XCTAssertFalse(native.player.automaticallyUpdateNowPlayingInfo)
      XCTAssertEqual(native.player.timeEventFrequency.getTime().seconds, 0.25)
      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(fixture.session.activationAttempts, previousActivations)
      waitForNativeCondition("The fresh real AVPlayer restores its retained position") {
        abs(native.player.currentTime - position) < 0.3
      }
      XCTAssertTrue(
        fixture.recorder.events.contains {
          $0.name == "playback-state" && $0.body["state"] as? String == "paused"
        })
      XCTAssertTrue(
        fixture.recorder.events.contains {
          $0.name == "remote-duck" && $0.body["paused"] as? Bool == true
            && $0.body["permanent"] as? Bool == false
        })
      XCTAssertTrue(
        fixture.recorder.events.contains {
          $0.name == "playback-play-when-ready-changed"
            && $0.body["playWhenReady"] as? Bool == false
        })
      let blocked = invokeNativeBridge {
        native.play(userInitiated: false, resolve: $0, reject: $1)
      }
      XCTAssertFalse(blocked.resolved)
      XCTAssertEqual(blocked.errorCode, "ios_audio_session_requires_explicit_play")
      XCTAssertEqual(fixture.session.activationAttempts, previousActivations)
      native.handleInterruption(type: .ended(shouldResume: true))
      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(fixture.session.activationAttempts, previousActivations)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      XCTAssertEqual(fixture.session.activationAttempts, previousActivations + 1)
      waitForNativeCondition("Explicit Play resumes on the replacement native owner") {
        native.player.playerState == .playing && native.player.currentTime > position
      }
    }

    func testRetiredOwnerEventsAndDelayedMetadataCannotOverwriteReplacement() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(options: ["progressUpdateEventInterval": 0.25])
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      let oldOwner = native.player
      let oldGeneration = try XCTUnwrap(fixture.generations.first)
      fixture.postMediaServicesReset()
      XCTAssertFalse(oldGeneration.isCurrent)
      waitForNativeCondition("The new owner metadata is visible") {
        fixture.infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "First track"
      }
      let previousCount = fixture.recorder.events.count
      let oldInfoCenter = GenerationScopedNowPlayingInfoCenter(
        generation: oldGeneration, center: fixture.infoCenter)
      oldInfoCenter.nowPlayingInfo = [MPMediaItemPropertyTitle: "Retired metadata"]
      let queuesDrained = expectation(description: "Retired owner event queues drain")
      queuesDrained.expectedFulfillmentCount = 5
      oldOwner.event.stateChange.addListener(self) { _ in
        DispatchQueue.main.async { queuesDrained.fulfill() }
      }
      oldOwner.event.fail.addListener(self) { _ in
        DispatchQueue.main.async { queuesDrained.fulfill() }
      }
      oldOwner.event.secondElapse.addListener(self) { _ in
        DispatchQueue.main.async { queuesDrained.fulfill() }
      }
      oldOwner.event.playWhenReadyChange.addListener(self) { _ in
        DispatchQueue.main.async { queuesDrained.fulfill() }
      }
      oldOwner.event.currentItem.addListener(self) { _ in
        DispatchQueue.main.async { queuesDrained.fulfill() }
      }
      oldOwner.event.stateChange.emit(data: .failed)
      oldOwner.event.fail.emit(data: NSError(domain: "RetiredOwner", code: 2))
      oldOwner.event.secondElapse.emit(data: 99)
      oldOwner.event.playWhenReadyChange.emit(data: true)
      oldOwner.event.currentItem.emit(
        data: (item: nil, index: nil, lastItem: nil, lastIndex: nil, lastPosition: 99))
      wait(for: [queuesDrained], timeout: 5)
      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(
        fixture.infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "First track")
      XCTAssertFalse(
        fixture.recorder.events.dropFirst(previousCount).contains { entry in
          entry.name == "playback-error" || entry.body["state"] as? String == "error"
            || entry.body["position"] as? Double == 99
        })
    }

    func testReplacementKeepsNativeRemoteCommandRegistrationsAndCapabilities() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(options: [
        "capabilities": ["play", "pause", "next", "previous"]
      ])
      XCTAssertTrue(
        invokeNativeBridge {
          native.setQueue(trackDicts: fixture.tracks(), resolve: $0, reject: $1)
        }.resolved)
      let oldController = native.player.remoteCommandController
      XCTAssertEqual(
        oldController.commandTargetPointers.keys.sorted(),
        ["NextTrackCommand", "Pause", "Play", "PreviousTrack", "TogglePlayPause"])
      fixture.postMediaServicesReset()
      let center = MPRemoteCommandCenter.shared()
      XCTAssertTrue(oldController.commandTargetPointers.isEmpty)
      XCTAssertEqual(
        native.player.remoteCommandController.commandTargetPointers.keys.sorted(),
        ["NextTrackCommand", "Pause", "Play", "PreviousTrack", "TogglePlayPause"])
      XCTAssertEqual(
        native.player.remoteCommands.map { $0.description },
        ["play", "pause", "nextTrack", "previousTrack", "togglePlayPause"])
      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertTrue(center.playCommand.isEnabled)
      XCTAssertTrue(center.pauseCommand.isEnabled)
      XCTAssertTrue(center.nextTrackCommand.isEnabled)
      XCTAssertTrue(center.previousTrackCommand.isEnabled)
      XCTAssertTrue(center.togglePlayPauseCommand.isEnabled)
    }
  }
#endif
