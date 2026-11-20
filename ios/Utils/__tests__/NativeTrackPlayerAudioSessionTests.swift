import AVFoundation
import MediaPlayer
import ObjectiveC
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
    var onActivate: (() -> Void)?

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
      onActivate?()
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
    func testRemovingDuplicateIndexesRemovesEachOriginalTrackOnce() throws {
      for activeIndex in [0, 1, 3] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp()
        let tracks: [[String: Any]] = ["A", "B", "C", "D"].map {
          ["id": $0, "url": fixture.audioURL.absoluteString]
        }
        XCTAssertTrue(
          invokeNativeBridge { native.setQueue(trackDicts: tracks, resolve: $0, reject: $1) }
            .resolved)
        XCTAssertTrue(
          invokeNativeBridge {
            native.skip(to: activeIndex, initialTime: -1, resolve: $0, reject: $1)
          }.resolved)
        let previousEvents = fixture.recorder.events.filter {
          $0.name == "playback-active-track-changed"
        }.count

        let outcome = invokeNativeBridge {
          native.remove(tracks: [1, 1], resolve: $0, reject: $1)
        }

        XCTAssertTrue(outcome.resolved)
        XCTAssertEqual(
          native.player.items.compactMap { ($0 as? Track)?.toObject()["id"] as? String },
          ["A", "C", "D"])
        XCTAssertEqual(native.player.currentIndex, activeIndex == 3 ? 2 : activeIndex)
        XCTAssertEqual(
          (native.player.currentItem as? Track)?.toObject()["id"] as? String,
          activeIndex == 0 ? "A" : activeIndex == 1 ? "C" : "D")
        XCTAssertEqual(
          fixture.recorder.events.filter { $0.name == "playback-active-track-changed" }.count,
          previousEvents + (activeIndex == 1 ? 1 : 0))
      }
    }

    func testRemovingUniqueIndexesAndRejectingInvalidIndexesPreservesOriginalIndexMeaning()
      throws
    {
      for indexes in [[1, 3], [1, 4], [-1, 1], []] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp()
        let tracks: [[String: Any]] = ["A", "B", "C", "D"].map {
          ["id": $0, "url": fixture.audioURL.absoluteString]
        }
        XCTAssertTrue(
          invokeNativeBridge { native.setQueue(trackDicts: tracks, resolve: $0, reject: $1) }
            .resolved)

        let outcome = invokeNativeBridge {
          native.remove(tracks: indexes, resolve: $0, reject: $1)
        }

        let invalid = indexes.contains { $0 < 0 || $0 >= tracks.count }
        XCTAssertEqual(outcome.resolved, !invalid)
        XCTAssertEqual(outcome.errorCode, invalid ? "index_out_of_bounds" : nil)
        XCTAssertEqual(
          native.player.items.compactMap { ($0 as? Track)?.toObject()["id"] as? String },
          indexes == [1, 3] ? ["A", "C"] : ["A", "B", "C", "D"])
        XCTAssertEqual(native.player.currentIndex, 0)
      }
    }

    func testAutomaticInterruptionHandlingResumesOnlyPreviouslyRequestedPlayback() throws {
      for wasPlaying in [true, false] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp(config: ["autoHandleInterruptions": true])
        XCTAssertTrue(
          invokeNativeBridge {
            native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
          }.resolved)
        if wasPlaying {
          XCTAssertTrue(
            invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }
              .resolved)
          waitForNativeCondition("Playback has started before the interruption") {
            native.player.playerState == .playing && native.player.currentTime > 0.1
          }
        }
        native.handleInterruption(type: .began)
        let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
        wrapper.player(didChangeTimeControlStatus: .paused)
        XCTAssertFalse(native.player.playWhenReady)
        let previousAttempts = fixture.session.activationAttempts

        native.handleInterruption(type: .ended(shouldResume: true))

        XCTAssertEqual(native.player.playWhenReady, wasPlaying)
        XCTAssertEqual(
          fixture.session.activationAttempts, previousAttempts + (wasPlaying ? 1 : 0))
      }
    }

    func testInterruptionHandlingRemainsApplicationControlledByDefault() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("Playback has started before the application handles its interruption")
      {
        native.player.playerState == .playing && native.player.currentTime > 0.1
      }
      native.handleInterruption(type: .began)
      let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
      wrapper.player(didChangeTimeControlStatus: .paused)
      let previousAttempts = fixture.session.activationAttempts

      native.handleInterruption(type: .ended(shouldResume: true))

      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(fixture.session.activationAttempts, previousAttempts)
      XCTAssertEqual(
        fixture.recorder.events.last { $0.name == "remote-duck" }?.body["paused"] as? Bool, false)
    }

    func testSystemInterruptionNotificationsPreserveEligibleResumeAndHonorExplicitPause() throws {
      for explicitlyPaused in [false, true] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp(config: ["autoHandleInterruptions": true])
        XCTAssertTrue(
          invokeNativeBridge {
            native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
          }.resolved)
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
        waitForNativeCondition("Playback starts before a system interruption notification") {
          native.player.playerState == .playing && native.player.currentTime > 0.1
        }
        NotificationCenter.default.post(
          name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
          userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
          ])
        let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
        wrapper.player(didChangeTimeControlStatus: .paused)
        if explicitlyPaused {
          XCTAssertTrue(invokeNativeBridge { native.pause(resolve: $0, reject: $1) }.resolved)
        }
        let previousAttempts = fixture.session.activationAttempts
        let positionBeforeEnd = native.player.currentTime

        NotificationCenter.default.post(
          name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
          userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume
              .rawValue,
          ])

        XCTAssertEqual(native.player.playWhenReady, !explicitlyPaused)
        XCTAssertEqual(
          fixture.session.activationAttempts, previousAttempts + (explicitlyPaused ? 0 : 1))
        if !explicitlyPaused {
          waitForNativeCondition("Authorized resume advances after both system observers run") {
            native.player.playerState == .playing
              && native.player.currentTime > positionBeforeEnd + 0.1
          }
        }
      }
    }

    private func postHeadsetRemoval(
      notificationCenter: NotificationCenter, onBackgroundQueue: Bool = false
    ) {
      let post = {
        notificationCenter.post(
          name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
          userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason
              .oldDeviceUnavailable
              .rawValue
          ])
      }
      if onBackgroundQueue {
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
          post()
          completed.signal()
        }
        XCTAssertEqual(
          completed.wait(timeout: .now() + 2), .success,
          "Publishing a route change must not wait for the main queue")
      } else {
        post()
      }
    }

    private func expectRouteLossCancelsAutomaticResume(
      autoHandleInterruptions: Bool, onBackgroundQueue: Bool, explicitPlayAfterRoute: Bool,
      shouldResume: Bool = true
    ) throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(
        config: autoHandleInterruptions ? ["autoHandleInterruptions": true] : [:])
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("Playback starts before an interruption followed by headset removal") {
        native.player.playerState == .playing && native.player.currentTime > 0.1
      }
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
      let eventsBeforeRoute = fixture.recorder.events.count
      let positionBeforeRoute = native.player.currentTime
      postHeadsetRemoval(
        notificationCenter: fixture.notificationCenter, onBackgroundQueue: onBackgroundQueue)
      if explicitPlayAfterRoute {
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      }
      let previousAttempts = fixture.session.activationAttempts
      let positionBeforeEnd = native.player.currentTime

      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
          AVAudioSessionInterruptionOptionKey: shouldResume
            ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0,
        ])

      let routeEvents = Array(fixture.recorder.events.dropFirst(eventsBeforeRoute))
      let pauseIndex = routeEvents.firstIndex { $0.name == "remote-pause" }
      let releaseIndex = routeEvents.firstIndex {
        $0.name == "remote-duck" && $0.body["paused"] as? Bool == false
      }
      if explicitPlayAfterRoute && onBackgroundQueue {
        XCTAssertNil(pauseIndex, "An older queued route signal cannot pause a newer explicit Play")
      } else {
        XCTAssertNotNil(pauseIndex, "The application must discard its interruption resume intent")
        if let pauseIndex = pauseIndex, let releaseIndex = releaseIndex {
          XCTAssertLessThan(pauseIndex, releaseIndex)
        }
      }
      XCTAssertNotNil(releaseIndex, "The application must leave its transient interruption state")
      XCTAssertFalse(routeEvents.contains { $0.body["permanent"] as? Bool == true })
      XCTAssertEqual(native.player.playWhenReady, explicitPlayAfterRoute)
      XCTAssertEqual(fixture.session.activationAttempts, previousAttempts)
      XCTAssertGreaterThanOrEqual(native.player.currentTime, positionBeforeRoute - 0.05)
      if explicitPlayAfterRoute {
        waitForNativeCondition("Explicit Play after headset removal keeps advancing") {
          native.player.playerState == .playing
            && native.player.currentTime > positionBeforeEnd + 0.1
        }
      }
    }

    func testHeadsetRemovalDuringInterruptionCancelsAutomaticResume() throws {
      for shouldResume in [false, true] {
        for autoHandleInterruptions in [false, true] {
          for onBackgroundQueue in [false, true] {
            try expectRouteLossCancelsAutomaticResume(
              autoHandleInterruptions: autoHandleInterruptions,
              onBackgroundQueue: onBackgroundQueue,
              explicitPlayAfterRoute: false, shouldResume: shouldResume)
          }
        }
      }
    }

    func testExplicitPlayAfterHeadsetRemovalIsPreservedWhenTheInterruptionEnds() throws {
      for shouldResume in [false, true] {
        for autoHandleInterruptions in [false, true] {
          for onBackgroundQueue in [false, true] {
            try expectRouteLossCancelsAutomaticResume(
              autoHandleInterruptions: autoHandleInterruptions,
              onBackgroundQueue: onBackgroundQueue,
              explicitPlayAfterRoute: true, shouldResume: shouldResume)
          }
        }
      }
    }

    func testNewerExplicitPlaySurvivesAnOlderInterruptionEndThatForbidsAutomaticResume() throws {
      for autoHandleInterruptions in [false, true] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp(
          config: autoHandleInterruptions ? ["autoHandleInterruptions": true] : [:])
        XCTAssertTrue(
          invokeNativeBridge {
            native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
          }
          .resolved)
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
        waitForNativeCondition("Playback starts before the interruption that becomes obsolete") {
          native.player.playerState == .playing && native.player.currentTime > 0.1
        }
        native.handleInterruption(type: .began)
        let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
        wrapper.player(didChangeTimeControlStatus: .paused)
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
        let eventsBeforeEnd = fixture.recorder.events.count

        native.handleInterruption(type: .ended(shouldResume: false))

        let endEvents = Array(fixture.recorder.events.dropFirst(eventsBeforeEnd))
        XCTAssertFalse(endEvents.contains { $0.body["permanent"] as? Bool == true })
        XCTAssertEqual(endEvents.last { $0.name == "remote-duck" }?.body["paused"] as? Bool, false)
        XCTAssertTrue(native.player.playWhenReady)
      }
    }

    func testQueuedInterruptionNotificationsCannotPauseOrStopANewerExplicitPlay() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      let eventsBeforeInterruption = fixture.recorder.events.count
      let posted = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        for type in [AVAudioSession.InterruptionType.began, .ended] {
          NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
        }
        posted.signal()
      }
      XCTAssertEqual(posted.wait(timeout: .now() + 2), .success)

      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      let delivered = expectation(
        description: "Queued interruption notifications have been delivered")
      DispatchQueue.main.async { delivered.fulfill() }
      wait(for: [delivered], timeout: 2)

      let interruptionEvents = fixture.recorder.events.dropFirst(eventsBeforeInterruption).filter {
        $0.name == "remote-duck"
      }
      XCTAssertFalse(interruptionEvents.contains { $0.body["paused"] as? Bool == true })
      XCTAssertFalse(interruptionEvents.contains { $0.body["permanent"] as? Bool == true })
      XCTAssertTrue(native.player.playWhenReady)
    }

    func testApplicationDuckPausePreservesMatchingPermanentInterruptionEndPolicy() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      native.handleInterruption(type: .began)
      XCTAssertTrue(invokeNativeBridge { native.pause(resolve: $0, reject: $1) }.resolved)

      native.handleInterruption(type: .ended(shouldResume: false))

      XCTAssertEqual(
        fixture.recorder.events.last { $0.name == "remote-duck" }?.body["permanent"] as? Bool, true)
      XCTAssertFalse(native.player.playWhenReady)
    }

    func testQueuedInterruptionNotificationsCannotPauseOrStopANewerSourceOwner() throws {
      for autoHandleInterruptions in [false, true] {
        for command in ["load", "skip", "setQueue", "remove", "reset", "mediaReset", "automaticAdvance"] {
          let fixture = try NativeSessionFixture()
          let native = try fixture.setUp(
            config: autoHandleInterruptions ? ["autoHandleInterruptions": true] : [:])
          XCTAssertTrue(
            invokeNativeBridge {
              native.setQueue(trackDicts: fixture.tracks(), resolve: $0, reject: $1)
            }.resolved)
          XCTAssertTrue(
            invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }
              .resolved)
          let posted = DispatchSemaphore(value: 0)
          DispatchQueue.global().async {
            for type in [AVAudioSession.InterruptionType.began, .ended] {
              NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
            }
            posted.signal()
          }
          XCTAssertEqual(posted.wait(timeout: .now() + 2), .success)

          switch command {
          case "load":
            XCTAssertTrue(
              invokeNativeBridge {
                native.load(trackDict: fixture.tracks()[1], resolve: $0, reject: $1)
              }.resolved)
          case "skip":
            XCTAssertTrue(
              invokeNativeBridge { native.skip(to: 1, initialTime: -1, resolve: $0, reject: $1) }
                .resolved)
          case "setQueue":
            XCTAssertTrue(
              invokeNativeBridge {
                native.setQueue(trackDicts: [fixture.tracks()[1]], resolve: $0, reject: $1)
              }.resolved)
          case "reset":
            XCTAssertTrue(invokeNativeBridge { native.reset(resolve: $0, reject: $1) }.resolved)
          case "remove":
            XCTAssertTrue(
              invokeNativeBridge { native.remove(tracks: [0, 1], resolve: $0, reject: $1) }.resolved)
          case "mediaReset":
            fixture.postMediaServicesReset()
          default:
            native.player.AVWrapperItemDidPlayToEndTime()
          }
          let playWhenReadyBeforeDelivery = native.player.playWhenReady
          let activationAttemptsBeforeDelivery = fixture.session.activationAttempts
          let eventsBeforeDelivery = fixture.recorder.events.count
          let delivered = expectation(
            description: "Queued interruption notifications are delivered after \(command)")
          DispatchQueue.main.async { delivered.fulfill() }
          wait(for: [delivered], timeout: 2)

          let interruptionEvents = fixture.recorder.events.dropFirst(eventsBeforeDelivery).filter {
            $0.name == "remote-duck"
          }
          XCTAssertFalse(
            interruptionEvents.contains { $0.body["paused"] as? Bool == true }, command)
          XCTAssertFalse(
            interruptionEvents.contains { $0.body["permanent"] as? Bool == true }, command)
          XCTAssertEqual(native.player.playWhenReady, playWhenReadyBeforeDelivery, command)
          XCTAssertEqual(
            fixture.session.activationAttempts, activationAttemptsBeforeDelivery, command)
          XCTAssertEqual(
            (native.player.currentItem as? Track)?.toObject()["id"] as? String,
            ["remove", "reset"].contains(command)
              ? nil : command == "mediaReset" ? "first-track" : "second-track",
            command)
        }
      }
    }

    func testQueuedHeadsetRemovalStillPausesAnAutomaticallyReplacedSource() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      let eventsBeforeRoute = fixture.recorder.events.count
      var replacementPlaybackRequests: [Bool] = []
      native.player.event.currentItem.addListener(self, onMainQueue: true) { [weak native] event in
        guard (event.item as? Track)?.toObject()["id"] as? String == "second-track",
          let native = native
        else { return }
        replacementPlaybackRequests.append(native.player.playWhenReady)
      }

      postHeadsetRemoval(notificationCenter: fixture.notificationCenter, onBackgroundQueue: true)
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[1], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertFalse(
        native.player.playWhenReady, "Source replacement must consume the route pause inline")
      XCTAssertEqual(replacementPlaybackRequests, [false])
      let automaticPlay = invokeNativeBridge {
        native.play(userInitiated: false, resolve: $0, reject: $1)
      }
      XCTAssertEqual(automaticPlay.errorCode, "ios_audio_session_requires_explicit_play")
      waitForNativeCondition("A route loss reaches the application after source replacement") {
        fixture.recorder.events.dropFirst(eventsBeforeRoute).contains { $0.name == "remote-pause" }
      }

      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(
        (native.player.currentItem as? Track)?.toObject()["id"] as? String, "second-track")
      _ = invokeNativeBridge { native.play(userInitiated: false, resolve: $0, reject: $1) }
      XCTAssertFalse(
        native.player.playWhenReady, "An automatic command cannot authorize speaker audio")
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(native.player.playWhenReady)
    }

    func testRecordedHeadsetRemovalPausesInternalQueueAdvanceAndRepeatBeforePlayback() throws {
      for repeatsCurrentTrack in [false, true] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp()
        XCTAssertTrue(
          invokeNativeBridge {
            native.setQueue(trackDicts: fixture.tracks(), resolve: $0, reject: $1)
          }.resolved)
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
        waitForNativeCondition(
          "Playback starts before internal source continuation after route loss"
        ) {
          native.player.playerState == .playing && native.player.currentTime > 0.1
        }
        let eventsBeforeRoute = fixture.recorder.events.count
        if repeatsCurrentTrack { native.player.repeatMode = .track }

        postHeadsetRemoval(notificationCenter: fixture.notificationCenter, onBackgroundQueue: true)
        if repeatsCurrentTrack {
          native.player.AVWrapperItemDidPlayToEndTime()
        } else {
          native.player.next()
        }

        XCTAssertFalse(
          native.player.playWhenReady,
          "Internal source continuation must consume the recorded route pause before returning")
        XCTAssertTrue(
          fixture.recorder.events.dropFirst(eventsBeforeRoute).contains {
            $0.name == "remote-pause"
          })
        XCTAssertEqual(native.player.currentIndex, repeatsCurrentTrack ? 0 : 1)
      }
    }

    func testHeadsetRemovalDuringExplicitPlayActivationStillRequiresANewerPlay() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      let eventsBeforeRoute = fixture.recorder.events.count
      fixture.session.onActivate = { [weak self, notificationCenter = fixture.notificationCenter] in
        self?.postHeadsetRemoval(notificationCenter: notificationCenter, onBackgroundQueue: true)
      }

      _ = invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }
      fixture.session.onActivate = nil
      waitForNativeCondition("A disconnect during activation is delivered after activation returns")
      {
        fixture.recorder.events.dropFirst(eventsBeforeRoute).contains { $0.name == "remote-pause" }
      }

      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(native.player.playWhenReady)
    }

    func testExplicitPlayDuringRoutePauseCallbackSuppressesObsoleteRemotePause() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("Playback starts before a reentrant Play during route pause") {
        native.player.playerState == .playing && native.player.currentTime > 0.1
      }
      let eventsBeforeRoute = fixture.recorder.events.count
      var replayedDuringPause = false
      native.player.event.playWhenReadyChange.addListener(self, onMainQueue: true) {
        [weak native] ready in
        guard !ready, !replayedDuringPause, let native = native
        else { return }
        replayedDuringPause = true
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      }

      postHeadsetRemoval(notificationCenter: fixture.notificationCenter, onBackgroundQueue: true)
      native.player.play()
      waitForNativeCondition("The Native route pause invokes a synchronous newer explicit Play") {
        replayedDuringPause
      }

      XCTAssertTrue(replayedDuringPause)
      XCTAssertTrue(native.player.playWhenReady)
      XCTAssertFalse(
        fixture.recorder.events.dropFirst(eventsBeforeRoute).contains { $0.name == "remote-pause" },
        "The disconnect must not send the application an obsolete pause after a newer explicit Play"
      )
    }

    func testRecordedRouteLossBlocksTransportBeforeQueuedPauseBeforeAndAfterReset() throws {
      for afterReset in [false, true] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp()
        XCTAssertTrue(
          invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
            .resolved)
        if afterReset { fixture.postMediaServicesReset() }
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
        waitForNativeCondition("The route-loss test has a ready, playing item") {
          native.player.playerState == .playing
        }
        XCTAssertTrue(invokeNativeBridge { native.pause(resolve: $0, reject: $1) }.resolved)
        let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
        let avPlayer = try XCTUnwrap(wrapper.playerTimeObserver.player)
        XCTAssertEqual(avPlayer.rate, 0)

        postHeadsetRemoval(notificationCenter: fixture.notificationCenter, onBackgroundQueue: true)
        native.player.play()

        XCTAssertEqual(avPlayer.rate, 0, "The recorded route loss must block the native rate")
        waitForNativeCondition("The pending route pause is delivered") {
          fixture.recorder.events.contains { $0.name == "remote-pause" }
        }
        XCTAssertFalse(native.player.playWhenReady)
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
        waitForNativeCondition("An explicit Play can authorize the current route") {
          native.player.playerState == .playing && avPlayer.rate > 0
        }
      }
    }

    func testRouteLossHasOneOwnerBeforeAndAfterMediaServicesReset() throws {
      for afterReset in [false, true] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp()
        XCTAssertTrue(
          invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
            .resolved)
        if afterReset { fixture.postMediaServicesReset() }
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
        waitForNativeCondition("The RNTP player is playing before the output disconnects") {
          native.player.playerState == .playing
        }
        let eventCount = fixture.recorder.events.count

        postHeadsetRemoval(notificationCenter: fixture.notificationCenter)
        XCTAssertFalse(native.player.playWhenReady)
        XCTAssertEqual(
          fixture.recorder.events.dropFirst(eventCount).filter { $0.name == "remote-pause" }.count,
          1)

        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
        postHeadsetRemoval(notificationCenter: .default)

        XCTAssertTrue(native.player.playWhenReady)
        XCTAssertEqual(
          fixture.recorder.events.dropFirst(eventCount).filter { $0.name == "remote-pause" }.count,
          1)
      }
    }

    func testExplicitCommandsAndSourceChangesCancelAutomaticInterruptionResume() throws {
      for command in ["pause", "stop", "playWhenReady", "skip", "load", "reset", "mediaReset"] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp(config: ["autoHandleInterruptions": true])
        XCTAssertTrue(
          invokeNativeBridge {
            native.setQueue(trackDicts: fixture.tracks(), resolve: $0, reject: $1)
          }.resolved)
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
        waitForNativeCondition("Playback has started before canceling resume with \(command)") {
          native.player.playerState == .playing && native.player.currentTime > 0.1
        }
        native.handleInterruption(type: .began)
        let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
        wrapper.player(didChangeTimeControlStatus: .paused)
        XCTAssertFalse(native.player.playWhenReady)
        switch command {
        case "pause":
          XCTAssertTrue(invokeNativeBridge { native.pause(resolve: $0, reject: $1) }.resolved)
        case "stop":
          XCTAssertTrue(invokeNativeBridge { native.stop(resolve: $0, reject: $1) }.resolved)
        case "playWhenReady":
          XCTAssertTrue(
            invokeNativeBridge {
              native.setPlayWhenReady(playWhenReady: false, resolve: $0, reject: $1)
            }.resolved)
        case "skip":
          XCTAssertTrue(
            invokeNativeBridge { native.skip(to: 1, initialTime: -1, resolve: $0, reject: $1) }
              .resolved)
          XCTAssertTrue(
            invokeNativeBridge { native.skip(to: 0, initialTime: -1, resolve: $0, reject: $1) }
              .resolved)
        case "load":
          XCTAssertTrue(
            invokeNativeBridge {
              native.load(trackDict: fixture.tracks()[1], resolve: $0, reject: $1)
            }.resolved)
        case "reset":
          XCTAssertTrue(invokeNativeBridge { native.reset(resolve: $0, reject: $1) }.resolved)
        default:
          fixture.postMediaServicesReset()
        }
        let previousAttempts = fixture.session.activationAttempts

        let eventsBeforeEnd = fixture.recorder.events.count
        native.handleInterruption(type: .ended(shouldResume: false))

        XCTAssertFalse(native.player.playWhenReady, command)
        XCTAssertEqual(fixture.session.activationAttempts, previousAttempts, command)
        if command != "pause" {
          XCTAssertFalse(
            fixture.recorder.events.dropFirst(eventsBeforeEnd).contains {
              $0.name == "remote-duck" && $0.body["permanent"] as? Bool == true
            }, "An obsolete interruption cannot stop the newer \(command) owner")
        }
      }
    }

    func testAutomaticResumeRequiresMatchingBeginAndConsumesResumePermissionOnEnd() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(config: ["autoHandleInterruptions": true])
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      let previousAttempts = fixture.session.activationAttempts

      native.handleInterruption(type: .ended(shouldResume: true))

      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(fixture.session.activationAttempts, previousAttempts)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("Playback has started before an interruption that forbids resume") {
        native.player.playerState == .playing && native.player.currentTime > 0.1
      }
      native.handleInterruption(type: .began)
      let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
      wrapper.player(didChangeTimeControlStatus: .paused)
      let attemptsBeforeEnd = fixture.session.activationAttempts

      native.handleInterruption(type: .ended(shouldResume: false))
      native.handleInterruption(type: .ended(shouldResume: true))

      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(fixture.session.activationAttempts, attemptsBeforeEnd)
    }

    func testRemoteToggleUsesPlaybackIntentForReadyStoppedEndedAndBufferingStates() throws {
      let states: [(AudioPlayerState, Bool)] = [
        (.ready, false), (.stopped, false), (.ended, false), (.buffering, true),
      ]
      for (state, playWhenReady) in states {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp(options: ["capabilities": ["play", "pause"]])
        XCTAssertTrue(
          invokeNativeBridge {
            native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
          }
          .resolved)
        waitForNativeCondition("The remote toggle has a loaded track") {
          native.player.playerState == .ready
        }
        native.player.playWhenReady = playWhenReady
        let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
        wrapper.state = state
        let event = try XCTUnwrap(
          class_createInstance(MPRemoteCommandEvent.self, 0) as? MPRemoteCommandEvent)

        let result = native.player.remoteCommandController.handleTogglePlayPauseCommand(event)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(
          fixture.recorder.events.last { $0.name == "remote-play" || $0.name == "remote-pause" }?
            .name,
          playWhenReady ? "remote-pause" : "remote-play", "Unexpected toggle for \(state)")
      }
    }

    func testRemoteToggleEmitsPlayAfterAnInterruptionThatForbidsAutomaticResume() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(
        config: ["autoHandleInterruptions": true], options: ["capabilities": ["play", "pause"]])
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("Playback starts before a system interruption") {
        native.player.playerState == .playing && native.player.currentTime > 0.1
      }
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
      waitForNativeCondition("The interruption pauses playback") {
        native.player.playerState == .paused
      }
      let positionBeforeInterruptionEnd = native.player.currentTime
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
          AVAudioSessionInterruptionOptionKey: 0,
        ])
      XCTAssertEqual(
        fixture.recorder.events.last { $0.name == "remote-duck" }?.body["permanent"] as? Bool, true)
      var playWhenReady: Bool?
      native.getPlayWhenReady(
        resolve: { playWhenReady = $0 as? Bool },
        reject: { _, _, _ in XCTFail("Reading playback intent should succeed") })
      XCTAssertEqual(playWhenReady, false)
      XCTAssertEqual(native.player.playerState, .paused)
      XCTAssertEqual(native.player.currentTime, positionBeforeInterruptionEnd, accuracy: 0.05)
      let event = try XCTUnwrap(
        class_createInstance(MPRemoteCommandEvent.self, 0) as? MPRemoteCommandEvent)

      let result = native.player.remoteCommandController.handleTogglePlayPauseCommand(event)

      XCTAssertEqual(result, .success)
      XCTAssertEqual(fixture.recorder.events.last?.name, "remote-play")
    }

    func testExplicitPlayDuringInterruptionEndSuppressesObsoletePermanentDuck() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(config: ["autoHandleInterruptions": true])
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("Playback starts before the interruption") {
        native.player.playerState == .playing && native.player.currentTime > 0.1
      }
      native.handleInterruption(type: .began)
      let eventsBeforeEnd = fixture.recorder.events.count
      var replayedDuringPause = false
      native.player.event.playWhenReadyChange.addListener(self, onMainQueue: true) {
        [weak native] ready in
        guard !ready, !replayedDuringPause, let native = native else { return }
        replayedDuringPause = true
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      }
      defer { native.player.event.playWhenReadyChange.removeListener(self) }

      native.handleInterruption(type: .ended(shouldResume: false))

      let endEvents = fixture.recorder.events.dropFirst(eventsBeforeEnd).filter {
        $0.name == "remote-duck"
      }
      XCTAssertTrue(replayedDuringPause)
      XCTAssertTrue(native.player.playWhenReady)
      XCTAssertFalse(endEvents.contains { $0.body["permanent"] as? Bool == true })
      XCTAssertEqual(endEvents.last?.body["paused"] as? Bool, false)
    }

    func testSkipDuringInitialLoadingPreservesRequestedPlayback() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge {
          native.setQueue(trackDicts: fixture.tracks(), resolve: $0, reject: $1)
        }
        .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
      wrapper.state = .loading
      XCTAssertTrue(native.player.playWhenReady)
      XCTAssertEqual(native.player.playerState, .loading)

      XCTAssertTrue(
        invokeNativeBridge { native.skip(to: 1, initialTime: -1, resolve: $0, reject: $1) }.resolved
      )

      XCTAssertTrue(native.player.playWhenReady)
      waitForNativeCondition("Skipping while loading starts the requested replacement") {
        native.player.playerState == .playing && native.player.currentTime > 0
      }
      XCTAssertEqual(
        (native.player.currentItem as? Track)?.toObject()["id"] as? String, "second-track")
    }

    func testSkipPreservesBufferingPlaybackIntentAndPausedIntent() throws {
      for playWhenReady in [true, false] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp()
        XCTAssertTrue(
          invokeNativeBridge {
            native.setQueue(trackDicts: fixture.tracks(), resolve: $0, reject: $1)
          }
          .resolved)
        waitForNativeCondition("The queue is ready before changing playback intent") {
          native.player.playerState == .ready
        }
        native.player.playWhenReady = playWhenReady
        let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
        wrapper.state = playWhenReady ? .buffering : .paused

        XCTAssertTrue(
          invokeNativeBridge { native.skip(to: 1, initialTime: -1, resolve: $0, reject: $1) }
            .resolved)

        XCTAssertEqual(native.player.playWhenReady, playWhenReady)
        waitForNativeCondition("The replacement follows the retained playback intent") {
          playWhenReady
            ? native.player.playerState == .playing : native.player.playerState == .ready
        }
        XCTAssertEqual(
          (native.player.currentItem as? Track)?.toObject()["id"] as? String, "second-track")
      }
    }

    func testCanceledSeekDoesNotPinRecoveryAfterStopOrRetryAndPlaybackAdvances() throws {
      for retry in [false, true] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp()
        XCTAssertTrue(
          invokeNativeBridge {
            native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
          }
          .resolved)
        XCTAssertEqual(native.player.playerState, .loading)
        XCTAssertTrue(
          invokeNativeBridge { native.seekTo(time: 18, resolve: $0, reject: $1) }.resolved)
        XCTAssertTrue(
          invokeNativeBridge {
            if retry {
              native.retry(resolve: $0, reject: $1)
            } else {
              native.stop(resolve: $0, reject: $1)
            }
          }.resolved)
        XCTAssertTrue(
          invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
        let minimumPosition = retry ? 18.7 : 0.7
        let maximumPosition = retry ? 25.0 : 10.0
        waitForNativeCondition("Playback advances after Stop discards or Retry preserves the seek")
        {
          native.player.playerState == .playing && native.player.currentTime > minimumPosition
            && native.player.currentTime < maximumPosition
        }
        XCTAssertTrue(invokeNativeBridge { native.pause(resolve: $0, reject: $1) }.resolved)
        let position = native.player.currentTime

        fixture.postMediaServicesReset()

        let restored = expectation(description: "Recovery restores the advanced position")
        native.player.event.seek.addListener(self) { event in
          if event.didFinish { DispatchQueue.main.async { restored.fulfill() } }
        }
        wait(for: [restored], timeout: 5)
        XCTAssertEqual(
          native.player.currentTime, position, accuracy: 0.3,
          "A canceled seek must not override playback that advanced after \(retry ? "Retry" : "Stop")"
        )
      }
    }

    func testPlayAfterStopStartsAtSeekRequestedAfterStop() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge {
          native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
        }.resolved)
      waitForNativeCondition("The source is ready before Stop") {
        native.player.playerState == .ready
      }

      XCTAssertTrue(invokeNativeBridge { native.stop(resolve: $0, reject: $1) }.resolved)
      let position = 18.0
      XCTAssertTrue(
        invokeNativeBridge { native.seekTo(time: position, resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)

      waitForNativeCondition("Playback advances from the requested position on the same source") {
        native.player.playerState == .playing && native.player.currentTime > position
      }
      XCTAssertEqual((native.player.currentItem as? Track)?.toObject()["id"] as? String, "first-track")
    }

    func testNegativeDeferredSeekRestoresZeroInsteadOfThePreviousCachedPosition() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition("The track is ready before establishing its previous position") {
        native.player.playerState == .ready
      }
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 9, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The earlier seek has reached its nonzero position") {
        abs(native.player.currentTime - 9) < 0.1
      }
      XCTAssertTrue(invokeNativeBridge { native.retry(resolve: $0, reject: $1) }.resolved)
      XCTAssertEqual(native.player.playerState, .loading)
      XCTAssertTrue(
        invokeNativeBridge { native.seekTo(time: -3, resolve: $0, reject: $1) }.resolved)

      fixture.postMediaServicesReset()

      let restored = expectation(description: "The normalized pending seek restores the beginning")
      native.player.event.seek.addListener(self) { event in
        if event.didFinish { DispatchQueue.main.async { restored.fulfill() } }
      }
      wait(for: [restored], timeout: 5)
      XCTAssertEqual(native.player.currentTime, 0, accuracy: 0.1)
      XCTAssertFalse(native.player.playWhenReady)
    }

    func testSupersededSameTargetSeekKeepsTheNewPendingRequestAcrossReset() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 8, resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 8, resolve: $0, reject: $1) }.resolved)

      fixture.postMediaServicesReset()

      waitForNativeCondition(
        "The newer same-target request survives cancellation of its predecessor"
      ) {
        abs(native.player.currentTime - 8) < 0.1
      }
      XCTAssertFalse(native.player.playWhenReady)
    }

    func testInternalSameTrackSeekToZeroBecomesRecoveryPosition() throws {
      for skipToNext in [false, true] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp()
        XCTAssertTrue(
          invokeNativeBridge {
            native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
          }
          .resolved)
        waitForNativeCondition("The track is ready before its first seek") {
          native.player.playerState == .ready
        }
        XCTAssertTrue(
          invokeNativeBridge { native.seekTo(time: 9, resolve: $0, reject: $1) }.resolved)
        waitForNativeCondition("The track has a nonzero recovery position") {
          abs(native.player.currentTime - 9) < 0.1
        }
        native.player.repeatMode = .queue
        XCTAssertTrue(
          invokeNativeBridge {
            if skipToNext {
              native.skipToNext(initialTime: -1, resolve: $0, reject: $1)
            } else {
              native.skip(to: 0, initialTime: -1, resolve: $0, reject: $1)
            }
          }.resolved)
        waitForNativeCondition("The internal replay seek reaches the beginning") {
          native.player.currentTime < 0.1
        }

        fixture.postMediaServicesReset()

        let restored = expectation(description: "Recovery restores the internal seek to zero")
        native.player.event.seek.addListener(self) { event in
          if event.didFinish { DispatchQueue.main.async { restored.fulfill() } }
        }
        wait(for: [restored], timeout: 5)
        XCTAssertEqual(native.player.currentTime, 0, accuracy: 0.1)
        XCTAssertFalse(native.player.playWhenReady)
      }
    }

    func testPendingInternalSameTrackSeekToZeroSurvivesImmediateMediaServicesReset() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition("The track is ready before establishing its cached nonzero position") {
        native.player.playerState == .ready
      }
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 9, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The previous recovery position has reached nine seconds") {
        abs(native.player.currentTime - 9) < 0.1
      }
      XCTAssertTrue(invokeNativeBridge { native.retry(resolve: $0, reject: $1) }.resolved)
      XCTAssertEqual(native.player.playerState, .loading)
      XCTAssertTrue(
        invokeNativeBridge { native.skip(to: 0, initialTime: -1, resolve: $0, reject: $1) }.resolved
      )
      XCTAssertEqual(native.player.playerState, .loading)

      fixture.postMediaServicesReset()

      let restored = expectation(description: "The pending internal seek restores the beginning")
      native.player.event.seek.addListener(self) { event in
        if event.didFinish { DispatchQueue.main.async { restored.fulfill() } }
      }
      wait(for: [restored], timeout: 5)
      XCTAssertEqual(native.player.currentTime, 0, accuracy: 0.1)
      XCTAssertFalse(native.player.playWhenReady)
    }

    func testStopThenMediaServicesResetResumesFromBeginningAndRetainsQueueAndSettings() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge {
          native.setQueue(trackDicts: fixture.tracks(), resolve: $0, reject: $1)
        }
        .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.skip(to: 1, initialTime: -1, resolve: $0, reject: $1) }.resolved
      )
      XCTAssertTrue(
        invokeNativeBridge { native.setRate(rate: 1.25, resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.setVolume(level: 0.4, resolve: $0, reject: $1) }.resolved)
      native.player.repeatMode = .queue
      waitForNativeCondition("The retained track is ready before its nonzero seek") {
        native.player.playerState == .ready
      }
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 9, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The recovery checkpoint reaches nine seconds before Stop") {
        abs(native.player.currentTime - 9) < 0.1
      }

      XCTAssertTrue(invokeNativeBridge { native.stop(resolve: $0, reject: $1) }.resolved)
      XCTAssertEqual(native.player.playerState, .stopped)
      XCTAssertEqual(native.player.currentTime, 0, accuracy: 0.1)
      fixture.postMediaServicesReset()

      waitForNativeCondition("The stopped track is restored after media-services reset") {
        native.player.playerState == .ready
      }
      XCTAssertEqual(native.player.currentTime, 0, accuracy: 0.1)
      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(
        native.player.items.compactMap { ($0 as? Track)?.toObject()["id"] as? String },
        ["first-track", "second-track"])
      XCTAssertEqual(native.player.currentIndex, 1)
      XCTAssertEqual(native.player.rate, 1.25)
      XCTAssertEqual(native.player.volume, 0.4)
      XCTAssertEqual(native.player.repeatMode, .queue)

      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("Play advances from the beginning after Stop and media-services reset")
      {
        native.player.playerState == .playing && native.player.currentTime > 0
      }
      XCTAssertLessThan(native.player.currentTime, 3)
    }

    func testStopKeepsRecoveryPositionOfSourceLoadedByStoppedStateListener() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition("The old track is ready before Stop") {
        native.player.playerState == .ready
      }
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 9, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The old track has a nonzero recovery checkpoint") {
        abs(native.player.currentTime - 9) < 0.1
      }
      var loadedReplacement = false
      native.player.event.stateChange.addListener(self, onMainQueue: true) { state in
        guard state == .stopped, !loadedReplacement else { return }
        loadedReplacement = true
        XCTAssertTrue(
          invokeNativeBridge {
            native.load(trackDict: fixture.tracks()[1], resolve: $0, reject: $1)
          }
          .resolved)
        XCTAssertTrue(
          invokeNativeBridge { native.seekTo(time: 12, resolve: $0, reject: $1) }.resolved)
      }

      XCTAssertTrue(invokeNativeBridge { native.stop(resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(loadedReplacement)
      fixture.postMediaServicesReset()

      waitForNativeCondition("The callback-selected track retains its own recovery position") {
        abs(native.player.currentTime - 12) < 0.1
      }
      XCTAssertEqual(
        (native.player.currentItem as? Track)?.toObject()["id"] as? String, "second-track")
      XCTAssertFalse(native.player.playWhenReady)
    }

    func testActiveTrackExplicitNullMetadataClearsPublishedValuesAndRetainsOmittedKeys() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(config: ["autoUpdateMetadata": false])
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition("The active track is ready for explicit metadata") {
        native.player.playerState == .ready
      }
      XCTAssertTrue(
        invokeNativeBridge {
          native.updateMetadata(
            for: 0,
            metadata: [
              "title": "Title", "artist": "Artist", "album": "Album", "duration": 120.0,
              "elapsedTime": 15.0, "isLiveStream": true,
            ], resolve: $0, reject: $1)
        }.resolved)
      waitForNativeCondition("All original metadata is published") {
        fixture.infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
          == 15
      }
      XCTAssertTrue(
        invokeNativeBridge {
          native.updateMetadata(
            for: 0,
            metadata: [
              "title": NSNull(), "artist": NSNull(), "album": NSNull(), "duration": NSNull(),
              "elapsedTime": NSNull(), "isLiveStream": NSNull(),
            ], resolve: $0, reject: $1)
        }.resolved)
      waitForNativeCondition("Explicit null clears the published active-track metadata") {
        fixture.infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] == nil
          && fixture.infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil
      }
      for key in [
        MPMediaItemPropertyTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle,
        MPMediaItemPropertyPlaybackDuration, MPNowPlayingInfoPropertyElapsedPlaybackTime,
        MPNowPlayingInfoPropertyIsLiveStream,
      ] {
        XCTAssertNil(fixture.infoCenter.nowPlayingInfo?[key])
      }
      let track = try XCTUnwrap(native.player.currentItem as? Track)
      XCTAssertNil(track.title)
      XCTAssertNil(track.artist)
      XCTAssertNil(track.album)
      XCTAssertNil(track.duration)
      XCTAssertNil(track.isLiveStream)
      XCTAssertTrue(
        invokeNativeBridge {
          native.updateNowPlayingMetadata(
            metadata: ["duration": 0.0, "elapsedTime": 0.0, "isLiveStream": false],
            resolve: $0, reject: $1)
        }.resolved)
      waitForNativeCondition("Zero and false metadata remain publishable") {
        fixture.infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false
      }
      XCTAssertEqual(
        fixture.infoCenter.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double, 0)
      XCTAssertEqual(
        fixture.infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double,
        0)
      XCTAssertNil(fixture.infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle])
    }

    func testFailedSourceReachesBridgeBeforeAReplacementIsLoaded() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      let failureDelivered = expectation(description: "The original source failure is delivered")
      native.player.event.fail.addListener(self) { _ in
        DispatchQueue.main.async { failureDelivered.fulfill() }
      }

      native.player.load(
        item: DefaultAudioItem(audioUrl: "http://[", title: "Failed track", sourceType: .stream),
        playWhenReady: true)
      let errorsBeforeReplacement = fixture.recorder.events.filter { $0.name == "playback-error" }
      XCTAssertEqual(errorsBeforeReplacement.count, 1)
      XCTAssertEqual(
        errorsBeforeReplacement.first?.body["code"] as? String, "ios_invalid_source_url")
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[1], resolve: $0, reject: $1) }
          .resolved)
      wait(for: [failureDelivered], timeout: 3)
      waitForNativeCondition("The valid replacement is ready after the earlier source failed") {
        native.player.playerState == .ready
      }

      XCTAssertEqual(fixture.recorder.events.filter { $0.name == "playback-error" }.count, 1)
      XCTAssertEqual(
        (native.player.currentItem as? Track)?.toObject()["id"] as? String, "second-track")
      let errorIndex = try XCTUnwrap(
        fixture.recorder.events.firstIndex { $0.name == "playback-error" })
      let loadingIndex = try XCTUnwrap(
        fixture.recorder.events.lastIndex {
          $0.name == "playback-state" && $0.body["state"] as? String == "loading"
        })
      XCTAssertLessThan(errorIndex, loadingIndex)
    }

    func testEndedStateKeepsItsTrackContextBeforeReplacementAndAnotherEnd() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      let tracks = try fixture.tracks().map { try XCTUnwrap(Track(dictionary: $0)) }
      native.player.add(items: tracks, playWhenReady: false)
      waitForNativeCondition("The first track is ready before its terminal event") {
        native.player.playerState == .ready
      }
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 9, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The first track reaches its own terminal position") {
        abs(native.player.currentTime - 9) < 0.1
      }
      let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
      let endsDelivered = expectation(description: "Both genuine ended state events are delivered")
      endsDelivered.expectedFulfillmentCount = 2
      native.player.event.stateChange.addListener(self) { state in
        if state == .ended { DispatchQueue.main.async { endsDelivered.fulfill() } }
      }

      wrapper.state = .ended
      XCTAssertEqual(
        fixture.recorder.events.filter { $0.name == "playback-queue-ended" }.count, 1,
        "The first end must reach the bridge before its source is replaced")
      XCTAssertTrue(
        invokeNativeBridge { native.skip(to: 1, initialTime: -1, resolve: $0, reject: $1) }.resolved
      )
      wrapper.state = .ended
      let statesBeforeDelivery = fixture.recorder.events.compactMap { entry in
        entry.name == "playback-state" ? entry.body["state"] as? String : nil
      }
      XCTAssertEqual(
        Array(statesBeforeDelivery.filter { $0 == "ended" || $0 == "loading" }.suffix(3)),
        ["ended", "loading", "ended"])
      wait(for: [endsDelivered], timeout: 3)

      let endedEvents = fixture.recorder.events.filter { $0.name == "playback-queue-ended" }
      XCTAssertEqual(endedEvents.count, 2)
      XCTAssertEqual(endedEvents.first?.body["track"] as? Int, 0)
      XCTAssertEqual(
        try XCTUnwrap(endedEvents.first?.body["position"] as? Double), 9, accuracy: 0.1)
      XCTAssertEqual(endedEvents.last?.body["track"] as? Int, 1)
      XCTAssertEqual(try XCTUnwrap(endedEvents.last?.body["position"] as? Double), 0, accuracy: 0.1)
    }

    func testEndedStateReachesBridgeBeforeBackwardSeekOnTheSameTrack() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      waitForNativeCondition("The track is ready before seeking to its terminal position") {
        native.player.playerState == .ready
      }
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 9, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The ended track has an observable terminal position") {
        abs(native.player.currentTime - 9) < 0.1
      }
      let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)

      wrapper.state = .ended
      let endedBeforeSeek = fixture.recorder.events.filter { $0.name == "playback-queue-ended" }
      XCTAssertEqual(endedBeforeSeek.count, 1)
      XCTAssertEqual(endedBeforeSeek.first?.body["position"] as? Double ?? -1, 9, accuracy: 0.1)
      XCTAssertTrue(invokeNativeBridge { native.seekTo(time: 2, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The backward seek starts a new timeline on the same track") {
        abs(native.player.currentTime - 2) < 0.1
      }

      let endedAfterSeek = fixture.recorder.events.filter { $0.name == "playback-queue-ended" }
      XCTAssertEqual(endedAfterSeek.count, 1)
      XCTAssertEqual(
        try XCTUnwrap(endedAfterSeek.first?.body["position"] as? Double), 9, accuracy: 0.1)
    }

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

  final class NativeTrackPlayerCompatibilityTests: XCTestCase {
    func testIndexedSkipPreservesTheSystemInterruptionBlock() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(config: ["autoHandleInterruptions": true])
      XCTAssertTrue(
        invokeNativeBridge {
          native.setQueue(trackDicts: fixture.tracks(), resolve: $0, reject: $1)
        }
        .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The current item is playing before the interruption") {
        native.player.playerState == .playing
      }
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
      XCTAssertTrue(native.player.playWhenReady)

      let eventsBeforeSkip = fixture.recorder.events.count
      XCTAssertTrue(
        invokeNativeBridge { native.skip(to: 1, initialTime: -1, resolve: $0, reject: $1) }.resolved
      )
      waitForNativeCondition("The replacement item is ready while the interruption is active") {
        native.player.wrapper.currentItem?.status == .readyToPlay
      }

      XCTAssertEqual(native.player.currentIndex, 1)
      XCTAssertEqual(native.player.currentTime, 0, accuracy: 0.01)
      XCTAssertFalse(
        fixture.recorder.events.dropFirst(eventsBeforeSkip).contains {
          $0.name == "playback-state" && $0.body["state"] as? String == "playing"
        })
    }

    func testRemoteToggleEmitsPlayAfterTheFinalItemEnds() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp(options: ["capabilities": ["play", "pause"]])
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      let endPosition = 29.8
      XCTAssertTrue(
        invokeNativeBridge { native.seekTo(time: endPosition, resolve: $0, reject: $1) }.resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The final item reaches the end of the queue") {
        native.player.playerState == .ended
      }
      let event = try XCTUnwrap(
        class_createInstance(MPRemoteCommandEvent.self, 0) as? MPRemoteCommandEvent)

      XCTAssertEqual(
        native.player.remoteCommandController.handleTogglePlayPauseCommand(event), .success)
      XCTAssertEqual(fixture.recorder.events.last?.name, "remote-play")
    }

    func testSetQueuePreservesPlayingAndPausedIntent() throws {
      for wasPlaying in [false, true] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp()
        XCTAssertTrue(
          invokeNativeBridge {
            native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
          }.resolved)
        if wasPlaying {
          XCTAssertTrue(
            invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }
              .resolved)
        }
        waitForNativeCondition("The original queue follows its requested playback intent") {
          native.player.playerState == (wasPlaying ? .playing : .ready)
        }
        let eventsBeforeReplacement = fixture.recorder.events.count
        let activationsBeforeReplacement = fixture.session.activationAttempts
        let deactivationsBeforeReplacement = fixture.session.deactivationAttempts

        XCTAssertTrue(
          invokeNativeBridge {
            native.setQueue(trackDicts: [fixture.tracks()[1]], resolve: $0, reject: $1)
          }.resolved)

        XCTAssertEqual(native.player.playWhenReady, wasPlaying)
        XCTAssertEqual(fixture.session.activationAttempts, activationsBeforeReplacement)
        XCTAssertEqual(fixture.session.deactivationAttempts, deactivationsBeforeReplacement)
        XCTAssertEqual(
          (native.player.currentItem as? Track)?.toObject()["id"] as? String, "second-track")
        XCTAssertTrue(
          fixture.recorder.events.dropFirst(eventsBeforeReplacement).contains {
            $0.name == "playback-active-track-changed"
              && ($0.body["track"] as? [String: Any])?["id"] as? String == "second-track"
          })
        guard native.player.playWhenReady == wasPlaying else { continue }
        waitForNativeCondition("The replacement queue preserves the original playback intent") {
          native.player.playerState == (wasPlaying ? .playing : .ready)
        }
      }
    }

    func testClearingQueueDeactivatesTheAudioSession() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge { native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      let deactivationsBeforeClear = fixture.session.deactivationAttempts

      XCTAssertTrue(
        invokeNativeBridge { native.setQueue(trackDicts: [], resolve: $0, reject: $1) }.resolved)

      XCTAssertNil(native.player.currentItem)
      XCTAssertEqual(fixture.session.deactivationAttempts, deactivationsBeforeClear + 1)
    }

    func testSingleItemQueueRepeatSkipKeepsNewerPositionAndPlaybackIntent() throws {
      for wasPlaying in [false, true] {
        for repeatedSkip in [false, true] {
          let fixture = try NativeSessionFixture()
          let native = try fixture.setUp()
          XCTAssertTrue(
            invokeNativeBridge {
              native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
            }.resolved)
          native.player.repeatMode = .queue
          if wasPlaying {
            XCTAssertTrue(
              invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }
                .resolved)
          }
          waitForNativeCondition("The single-item queue follows its original playback intent") {
            native.player.playerState == (wasPlaying ? .playing : .ready)
          }
          if repeatedSkip {
            XCTAssertTrue(
              invokeNativeBridge {
                native.skipToNext(initialTime: -1, resolve: $0, reject: $1)
              }.resolved)
          }

          XCTAssertTrue(
            invokeNativeBridge {
              native.skipToNext(initialTime: 8, resolve: $0, reject: $1)
            }.resolved)

          XCTAssertEqual(native.player.playWhenReady, wasPlaying)
          XCTAssertEqual(native.player.currentIndex, 0)
          guard native.player.playWhenReady == wasPlaying else { continue }
          waitForNativeCondition("The newest skip position retains the original playback intent") {
            native.player.playerState == (wasPlaying ? .playing : .ready)
              && native.player.currentTime >= 8 && native.player.currentTime < 12
          }
        }
      }
    }

    func testFailedInitialSeekPositionSurvivesMediaServicesResetWithoutChangingReportedProgress()
      throws
    {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge {
          native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
        }.resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.seekTo(time: 25, resolve: $0, reject: $1) }.resolved)
      let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
      wrapper.itemFailedToPlayToEndTime()
      XCTAssertEqual(native.player.playerState, .failed)
      var positionBeforeReset: Double?
      native.getProgress(
        resolve: { positionBeforeReset = ($0 as? [String: Any])?["position"] as? Double },
        reject: { _, _, _ in XCTFail("Reading failed-source progress should succeed") })
      XCTAssertEqual(try XCTUnwrap(positionBeforeReset), 0, accuracy: 0.1)

      fixture.postMediaServicesReset()

      let restored = expectation(description: "The failed initial resume seek is restored")
      native.player.event.seek.addListener(self) { event in
        if event.didFinish { DispatchQueue.main.async { restored.fulfill() } }
      }
      wait(for: [restored], timeout: 5)
      XCTAssertEqual(native.player.currentTime, 25, accuracy: 0.1)
      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(
        (native.player.currentItem as? Track)?.toObject()["id"] as? String, "first-track")
    }

    func testStopNewSourceAndExplicitZeroSupersedeFailedResumePositionBeforeReset() throws {
      for command in ["stop", "source", "zero"] {
        let fixture = try NativeSessionFixture()
        let native = try fixture.setUp()
        XCTAssertTrue(
          invokeNativeBridge {
            native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
          }.resolved)
        XCTAssertTrue(
          invokeNativeBridge { native.seekTo(time: 25, resolve: $0, reject: $1) }.resolved)
        let wrapper = try XCTUnwrap(native.player.wrapper as? AVPlayerWrapper)
        wrapper.itemFailedToPlayToEndTime()
        switch command {
        case "stop":
          XCTAssertTrue(invokeNativeBridge { native.stop(resolve: $0, reject: $1) }.resolved)
        case "source":
          XCTAssertTrue(
            invokeNativeBridge {
              native.load(trackDict: fixture.tracks()[1], resolve: $0, reject: $1)
            }.resolved)
        default:
          XCTAssertTrue(
            invokeNativeBridge { native.seekTo(time: 0, resolve: $0, reject: $1) }.resolved)
        }

        fixture.postMediaServicesReset()

        let restored = expectation(description: "The newer \(command) position is restored")
        native.player.event.seek.addListener(self) { event in
          if event.didFinish { DispatchQueue.main.async { restored.fulfill() } }
        }
        wait(for: [restored], timeout: 5)
        XCTAssertEqual(native.player.currentTime, 0, accuracy: 0.1, command)
        XCTAssertFalse(native.player.playWhenReady, command)
        XCTAssertEqual(
          (native.player.currentItem as? Track)?.toObject()["id"] as? String,
          command == "source" ? "second-track" : "first-track")
      }
    }
  }
  final class NativeTrackPlayerQueueEndTests: XCTestCase {
    func testPauseBeforeFinalEndDeliveryStillReportsTheQueueEnd() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge {
          native.load(trackDict: fixture.tracks()[0], resolve: $0, reject: $1)
        }.resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The final item is playing before its end notification") {
        native.player.playerState == .playing
      }
      let item = try XCTUnwrap(native.player.wrapper.currentItem)
      let notificationPosted = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        notificationPosted.signal()
      }
      XCTAssertEqual(notificationPosted.wait(timeout: .now() + 5), .success)

      XCTAssertTrue(invokeNativeBridge { native.pause(resolve: $0, reject: $1) }.resolved)
      let delivery = expectation(description: "The end notification is processed on main")
      DispatchQueue.main.async { delivery.fulfill() }
      wait(for: [delivery], timeout: 5)

      XCTAssertEqual(native.player.playerState, .ended)
      XCTAssertFalse(native.player.playWhenReady)
      let endedEvents = fixture.recorder.events.filter { $0.name == "playback-queue-ended" }
      XCTAssertEqual(endedEvents.count, 1)
      XCTAssertEqual(endedEvents.first?.body["track"] as? Int, 0)
    }

    func testIndexedSkipAfterNaturalQueueEndLoadsTheSelectedTrackPaused() throws {
      let fixture = try NativeSessionFixture()
      let native = try fixture.setUp()
      XCTAssertTrue(
        invokeNativeBridge {
          native.setQueue(trackDicts: fixture.tracks(), resolve: $0, reject: $1)
        }.resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.skip(to: 1, initialTime: 29.8, resolve: $0, reject: $1) }
          .resolved)
      XCTAssertTrue(
        invokeNativeBridge { native.play(userInitiated: true, resolve: $0, reject: $1) }.resolved)
      waitForNativeCondition("The final item reaches natural end of queue") {
        native.player.playerState == .ended
      }
      let eventsBeforeSkip = fixture.recorder.events.count

      XCTAssertTrue(
        invokeNativeBridge { native.skip(to: 0, initialTime: -1, resolve: $0, reject: $1) }
          .resolved)

      XCTAssertFalse(native.player.playWhenReady)
      XCTAssertEqual(native.player.currentIndex, 0)
      waitForNativeCondition("The selected item is ready to play on request") {
        native.player.wrapper.currentItem?.status == .readyToPlay
      }
      XCTAssertEqual(native.player.currentTime, 0, accuracy: 0.01)
      XCTAssertFalse(
        fixture.recorder.events.dropFirst(eventsBeforeSkip).contains {
          $0.name == "playback-state" && $0.body["state"] as? String == "playing"
        })
    }
  }
#endif
