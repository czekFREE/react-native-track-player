import AVFoundation
import XCTest

private func runOnBackgroundAndWaitForCompletion(_ action: @escaping () -> Void) {
  let completed = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    XCTAssertFalse(Thread.isMainThread)
    action()
    completed.signal()
  }
  XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
}

private final class WrapperLoadingAsset: AVURLAsset, @unchecked Sendable {
  private var playableCompletion: (() -> Void)?
  private var playableStatus = AVKeyValueStatus.unknown
  var reportedDuration = CMTime(seconds: 60, preferredTimescale: 1000)

  override func loadValuesAsynchronously(
    forKeys keys: [String], completionHandler handler: (() -> Void)? = nil
  ) {
    if keys == ["playable"] { playableCompletion = handler }
  }

  override func statusOfValue(forKey key: String, error outError: NSErrorPointer)
    -> AVKeyValueStatus
  {
    if key == "duration" { return .loaded }
    return key == "playable" ? playableStatus : .unknown
  }

  override var isPlayable: Bool { true }
  override var duration: CMTime { reportedDuration }
  override func cancelLoading() {}

  func finishPlayable() {
    playableStatus = .loaded
    playableCompletion?()
  }

  func failPlayable() {
    playableStatus = .failed
    playableCompletion?()
  }
}

private class WrapperTransportPlayer: AVPlayer {
  private var reportedStatus = AVPlayer.TimeControlStatus.paused
  private var reportedPlayerStatus = AVPlayer.Status.unknown
  private var reportedRate: Float = 0
  private var position = CMTime.zero
  override var status: AVPlayer.Status { reportedPlayerStatus }
  override var timeControlStatus: AVPlayer.TimeControlStatus { reportedStatus }
  override var rate: Float {
    get { reportedRate }
    set { reportedRate = newValue }
  }
  override func currentTime() -> CMTime { position }

  func reportTimeControlStatus(_ status: AVPlayer.TimeControlStatus, rate: Float? = nil) {
    willChangeValue(forKey: "timeControlStatus")
    reportedStatus = status
    if let rate = rate {
      reportedRate = rate
    } else if status == .paused {
      reportedRate = 0
    }
    if status == .playing { position = CMTime(seconds: 10, preferredTimescale: 1000) }
    didChangeValue(forKey: "timeControlStatus")
  }

  func reportFailure() {
    willChangeValue(forKey: "status")
    reportedPlayerStatus = .failed
    didChangeValue(forKey: "status")
  }

  func reportPosition(_ seconds: Double) {
    position = CMTime(seconds: seconds, preferredTimescale: 1000)
  }
}

private final class WrapperManualItemTransportPlayer: WrapperTransportPlayer {
  private var installedItem: AVPlayerItem?
  var onCurrentItemRead: (() -> Void)?
  override var currentItem: AVPlayerItem? {
    let item = installedItem
    onCurrentItemRead?()
    return item
  }
  override func replaceCurrentItem(with item: AVPlayerItem?) { installedItem = item }
}

private final class WrapperSeekingPlayer: AVPlayer {
  var targets: [Double] = []
  var completions: [(Bool) -> Void] = []
  var position = CMTime.zero
  override func currentTime() -> CMTime { position }
  override func seek(
    to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
    completionHandler: @escaping (Bool) -> Void
  ) {
    targets.append(time.seconds)
    completions.append(completionHandler)
  }
}

private class WrapperControlledSeekingPlayer: WrapperTransportPlayer {
  private var installedItem: AVPlayerItem?
  var targets: [Double] = []
  var completions: [(Bool) -> Void] = []
  var ratesAtInstallation: [Float] = []
  var ratesAtSeekStart: [Float] = []
  var startedItems: [AVPlayerItem] = []
  var onPlaybackStart: (() -> Void)?

  override var currentItem: AVPlayerItem? { installedItem }
  override var rate: Float {
    get { super.rate }
    set {
      super.rate = newValue
      if newValue != 0, let item = installedItem {
        startedItems.append(item)
        onPlaybackStart?()
      }
    }
  }
  override func replaceCurrentItem(with item: AVPlayerItem?) {
    installedItem = item
    if let item = item {
      ratesAtInstallation.append(rate)
      if rate != 0 { startedItems.append(item) }
    }
  }
  override func seek(
    to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
    completionHandler: @escaping (Bool) -> Void
  ) {
    targets.append(time.seconds)
    ratesAtSeekStart.append(rate)
    completions.append(completionHandler)
  }
}

private final class WrapperSynchronousPauseSeekingPlayer: WrapperControlledSeekingPlayer {
  var soughtItems: [AVPlayerItem] = []

  override var rate: Float {
    get { super.rate }
    set {
      super.rate = newValue
      if newValue == 0, timeControlStatus != .paused {
        reportTimeControlStatus(.paused)
      }
    }
  }

  override func seek(
    to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
    completionHandler: @escaping (Bool) -> Void
  ) {
    if let item = currentItem { soughtItems.append(item) }
    super.seek(
      to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter,
      completionHandler: completionHandler)
  }
}

private final class WrapperStatusItem: AVPlayerItem, @unchecked Sendable {
  private var reportedStatus = AVPlayerItem.Status.unknown
  var reportedDuration = CMTime(seconds: 60, preferredTimescale: 1000)
  var reportedSeekableTimeRanges: [NSValue] = []
  private var reportedLoadedTimeRanges: [NSValue] = []
  private var reportedBufferEmpty = false
  private var reportedBufferFull = false
  private var reportedLikelyToKeepUp = false
  override var status: AVPlayerItem.Status { reportedStatus }
  override var isPlaybackBufferEmpty: Bool { reportedBufferEmpty }
  override var isPlaybackBufferFull: Bool { reportedBufferFull }
  override var isPlaybackLikelyToKeepUp: Bool { reportedLikelyToKeepUp }
  override var duration: CMTime { reportedDuration }
  override var seekableTimeRanges: [NSValue] { reportedSeekableTimeRanges }
  override var loadedTimeRanges: [NSValue] { reportedLoadedTimeRanges }

  func reportPlaybackBufferEmpty(_ isEmpty: Bool) {
    willChangeValue(forKey: "playbackBufferEmpty")
    reportedBufferEmpty = isEmpty
    didChangeValue(forKey: "playbackBufferEmpty")
  }

  func reportPlaybackBufferFull(_ isFull: Bool) {
    willChangeValue(forKey: "playbackBufferFull")
    reportedBufferFull = isFull
    didChangeValue(forKey: "playbackBufferFull")
  }

  func reportPlaybackLikelyToKeepUp(_ isLikelyToKeepUp: Bool) {
    willChangeValue(forKey: "playbackLikelyToKeepUp")
    reportedLikelyToKeepUp = isLikelyToKeepUp
    didChangeValue(forKey: "playbackLikelyToKeepUp")
  }

  func fail() {
    willChangeValue(forKey: "status")
    reportedStatus = .failed
    didChangeValue(forKey: "status")
  }

  func reportLoadedTimeRanges(_ ranges: [NSValue]) {
    willChangeValue(forKey: "loadedTimeRanges")
    reportedLoadedTimeRanges = ranges
    didChangeValue(forKey: "loadedTimeRanges")
  }

  func reportDuration(_ duration: CMTime) {
    willChangeValue(forKey: "duration")
    reportedDuration = duration
    didChangeValue(forKey: "duration")
  }
}

private final class WrapperCorrectnessDelegate: AVPlayerWrapperDelegate {
  var failures = 0
  var lastError: Error?
  var endFailures = 0
  var seeks: [Double] = []
  var seekOutcomes: [Bool] = []
  var states: [AVPlayerWrapperState] = []
  var durations: [Double] = []
  var ended = 0
  var onState: ((AVPlayerWrapperState) -> Void)?
  var onFailure: (() -> Void)?
  var onSeek: ((Double) -> Void)?
  var onInstallItem: ((AVPlayerItem) -> Void)?
  var onPlayWhenReady: ((Bool) -> Void)?
  func AVWrapper(didChangeState state: AVPlayerWrapperState) {
    states.append(state)
    onState?(state)
  }
  func AVWrapper(secondsElapsed seconds: Double) {}
  func AVWrapper(failedWithError error: Error?) {
    failures += 1
    lastError = error
    onFailure?()
  }
  func AVWrapper(seekTo seconds: Double, didFinish: Bool) {
    XCTAssertTrue(Thread.isMainThread)
    seeks.append(seconds)
    seekOutcomes.append(didFinish)
    onSeek?(seconds)
  }
  func AVWrapper(didUpdateDuration duration: Double) { durations.append(duration) }
  func AVWrapper(didReceiveCommonMetadata metadata: [AVMetadataItem]) {}
  func AVWrapper(didReceiveChapterMetadata metadata: [AVTimedMetadataGroup]) {}
  func AVWrapper(didReceiveTimedMetadata metadata: [AVTimedMetadataGroup]) {}
  func AVWrapper(didChangePlayWhenReady playWhenReady: Bool) {
    onPlayWhenReady?(playWhenReady)
  }
  func AVWrapper(didInstallItem item: AVPlayerItem) {
    XCTAssertTrue(Thread.isMainThread)
    onInstallItem?(item)
  }
  func AVWrapperItemDidPlayToEndTime() { ended += 1 }
  func AVWrapperItemFailedToPlayToEndTime() { endFailures += 1 }
  func AVWrapperItemPlaybackStalled() {}
  func AVWrapperDidRecreateAVPlayer() {}
}

private final class WrapperItemObserverDelegate: AVPlayerItemObserverDelegate {
  var failures = 0
  var durations: [Double] = []
  var onFailure: (() -> Void)?
  func item(statusDidChange status: AVPlayerItem.Status) {
    XCTAssertTrue(Thread.isMainThread)
    if status == .failed {
      failures += 1
      onFailure?()
    }
  }
  func item(didUpdateDuration duration: Double) { durations.append(duration) }
  func item(didUpdatePlaybackLikelyToKeepUp playbackLikelyToKeepUp: Bool) {}
  func item(didReceiveTimedMetadata metadata: [AVTimedMetadataGroup]) {}
}

private final class WrapperNotificationDelegate: AVPlayerItemNotificationObserverDelegate {
  var ended = 0
  var onEnd: (() -> Void)?
  func itemDidPlayToEndTime() {
    XCTAssertTrue(Thread.isMainThread)
    ended += 1
    onEnd?()
  }
  func itemFailedToPlayToEndTime() {}
  func itemPlaybackStalled() {}
}

final class SwiftAudioExWrapperCorrectnessTests: XCTestCase {

  private let trackURL = URL(fileURLWithPath: "/yrt-tests/wrapper-track.mp3")

  func testBlockingSeekCannotPublishPlayingFromTransportOrBoundaryCallbacks() {
    let player = WrapperControlledSeekingPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true, initialTime: 25)
    asset.finishPlayable()
    drainMainQueue()
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(wrapper.pendingSeekPosition, 25)

    player.reportTimeControlStatus(.playing, rate: 0)
    XCTAssertNotEqual(wrapper.state, .playing)
    wrapper.audioDidStart()

    XCTAssertNotEqual(wrapper.state, .playing)
    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)
    wrapper.unload()
  }

  func testLateAudioBoundaryCannotReviveFailedItem() {
    let player = WrapperControlledSeekingPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    wrapper.itemFailedToPlayToEndTime()
    XCTAssertEqual(wrapper.state, .failed)
    player.reportTimeControlStatus(.playing, rate: 0)

    wrapper.audioDidStart()

    XCTAssertEqual(wrapper.state, .failed)
    wrapper.unload()
  }

  private func drainMainQueue() {
    let drained = expectation(description: "queued callbacks finish")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  func testToggleDuringLoadingCancelsPendingAutoplay() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperTransportPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    XCTAssertNil(wrapper.currentItem)
    XCTAssertEqual(player.timeControlStatus, .paused)

    wrapper.togglePlaying()

    XCTAssertFalse(wrapper.playWhenReady)
    asset.finishPlayable()
    drainMainQueue()
    XCTAssertNotNil(wrapper.currentItem)
    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.avPlayer.rate, 0)
    wrapper.unload()
  }

  func testConsecutiveTogglesFollowIntentBeforeNativeStatusChanges() {
    let player = WrapperTransportPlayer()
    let wrapper = AVPlayerWrapper(player: player)
    XCTAssertEqual(player.timeControlStatus, .paused)

    wrapper.togglePlaying()
    XCTAssertTrue(wrapper.playWhenReady)
    wrapper.togglePlaying()

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)
  }

  func testToggleAtEndRequestsPlaybackWithRetainedIntent() {
    let (wrapper, player, _) = makePlayingStallFixture()
    player.reportPosition(60)
    player.reportTimeControlStatus(.paused)
    wrapper.state = .ended
    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)

    wrapper.togglePlaying()

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 1)
    wrapper.unload()
  }

  func testUnloadRetiresSourceBeforeReloadStopAndPlay() {
    let asset = WrapperLoadingAsset(url: trackURL)
    var loadedURLs: [URL] = []
    let wrapper = AVPlayerWrapper(makeAsset: { url, _ in
      loadedURLs.append(url)
      return asset
    })
    wrapper.load(from: trackURL, playWhenReady: false, options: ["old": true])

    wrapper.unload()
    wrapper.reload(startFromCurrentTime: false)
    wrapper.stop()
    wrapper.play()

    XCTAssertEqual(loadedURLs, [trackURL])
    XCTAssertNil(wrapper.url)
    XCTAssertNil(wrapper.urlOptions)
    XCTAssertNil(wrapper.currentItem)
    XCTAssertNil(wrapper.asset)
    wrapper.unload()
  }

  func testStopRetainsSourceForExplicitPlaybackRestart() {
    var loadedURLs: [URL] = []
    let wrapper = AVPlayerWrapper(makeAsset: { url, _ in
      loadedURLs.append(url)
      return WrapperLoadingAsset(url: url)
    })
    wrapper.load(from: trackURL, playWhenReady: false)

    wrapper.stop()
    wrapper.play()

    XCTAssertEqual(loadedURLs, [trackURL, trackURL])
    XCTAssertEqual(wrapper.url, trackURL)
    XCTAssertTrue(wrapper.playWhenReady)
    wrapper.unload()
  }

  func testUnloadCancellationCallbackCanInstallReplacementSource() {
    let replacementURL = URL(fileURLWithPath: "/yrt-tests/replacement.mp3")
    let wrapper = AVPlayerWrapper(makeAsset: { url, _ in WrapperLoadingAsset(url: url) })
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.seek(to: 10) { finished in
      XCTAssertFalse(finished)
      wrapper.load(from: replacementURL, playWhenReady: false, options: ["replacement": true])
    }

    wrapper.unload()

    XCTAssertEqual(wrapper.url, replacementURL)
    XCTAssertEqual(wrapper.urlOptions?["replacement"] as? Bool, true)
    XCTAssertEqual((wrapper.asset as? AVURLAsset)?.url, replacementURL)
    XCTAssertEqual(wrapper.state, .loading)
    wrapper.unload()
  }

  func testReplacementTrackDoesNotInheritDeferredSeek() {
    let oldAsset = WrapperLoadingAsset(url: trackURL)
    let nextAsset = WrapperLoadingAsset(url: trackURL)
    var assets = [oldAsset, nextAsset]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in assets.removeFirst() })
    let player = WrapperSeekingPlayer()
    wrapper.avPlayer = player
    wrapper.load(from: trackURL, playWhenReady: false, initialTime: 25)

    wrapper.load(from: trackURL, playWhenReady: false)
    nextAsset.finishPlayable()
    drainMainQueue()

    XCTAssertTrue(wrapper.currentItem?.asset === nextAsset)
    XCTAssertTrue(player.targets.isEmpty)
    wrapper.unload()
  }

  func testLateSeekFromReplacedTrackCannotPublishCurrentTrackPosition() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    asset.finishPlayable()
    drainMainQueue()
    wrapper.seek(to: 25)
    wrapper.unload()
    player.replaceCurrentItem(with: AVPlayerItem(url: trackURL))

    player.completions[0](true)
    drainMainQueue()

    XCTAssertEqual(delegate.seeks, [25])
    XCTAssertEqual(delegate.seekOutcomes, [false])
    wrapper.unload()
  }

  func testCancelledSeekEmitsFailureAndSuccessfulSeekEmitsSuccess() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    asset.finishPlayable()
    drainMainQueue()
    wrapper.seek(to: 25)
    player.completions[0](false)
    drainMainQueue()
    XCTAssertEqual(delegate.seeks, [25])
    XCTAssertEqual(delegate.seekOutcomes, [false])

    wrapper.seek(to: 12)
    player.completions[1](true)
    drainMainQueue()

    XCTAssertEqual(delegate.seeks, [25, 12])
    XCTAssertEqual(delegate.seekOutcomes, [false, true])
    wrapper.unload()
  }

  func testFailedPlayerRecoveryPreservesPlaybackSettings() {
    let wrapper = AVPlayerWrapper()
    wrapper.volume = 0.25
    wrapper.isMuted = true
    wrapper.automaticallyWaitsToMinimizeStalling = false
    wrapper.rate = 1.5
    let previousPlayer = wrapper.avPlayer
    wrapper.itemFailedToPlayToEndTime()

    wrapper.load()

    XCTAssertFalse(wrapper.avPlayer === previousPlayer)
    XCTAssertEqual(wrapper.volume, 0.25)
    XCTAssertTrue(wrapper.isMuted)
    XCTAssertFalse(wrapper.automaticallyWaitsToMinimizeStalling)
    XCTAssertEqual(wrapper.rate, 1.5)
  }

  func testBufferDurationUpdatesCurrentAndReplacementItems() throws {
    let firstAsset = WrapperLoadingAsset(url: trackURL)
    let nextAsset = WrapperLoadingAsset(url: trackURL)
    var assets = [firstAsset, nextAsset]
    let player = WrapperTransportPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: true)
    firstAsset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    let firstItem = try XCTUnwrap(wrapper.currentItem)

    wrapper.bufferDuration = 12

    XCTAssertEqual(wrapper.state, .playing)
    XCTAssertEqual(firstItem.preferredForwardBufferDuration, 12)
    wrapper.load(from: trackURL, playWhenReady: false)
    nextAsset.finishPlayable()
    drainMainQueue()
    let nextItem = try XCTUnwrap(wrapper.currentItem)
    XCTAssertFalse(nextItem === firstItem)
    XCTAssertEqual(nextItem.preferredForwardBufferDuration, 12)
    wrapper.unload()
  }

  #if os(iOS)
    func testAutomaticStallingResetUpdatesCurrentItemBufferDuration() throws {
      let audioPlayer = AudioPlayer()
      let wrapper = try XCTUnwrap(audioPlayer.wrapper as? AVPlayerWrapper)
      let item = AVPlayerItem(url: trackURL)
      wrapper.avPlayer.replaceCurrentItem(with: item)
      audioPlayer.bufferDuration = 12
      XCTAssertEqual(item.preferredForwardBufferDuration, 12)
      XCTAssertFalse(audioPlayer.automaticallyWaitsToMinimizeStalling)

      audioPlayer.automaticallyWaitsToMinimizeStalling = true

      XCTAssertEqual(audioPlayer.bufferDuration, 0)
      XCTAssertEqual(item.preferredForwardBufferDuration, 0)
      XCTAssertTrue(audioPlayer.automaticallyWaitsToMinimizeStalling)
      wrapper.unload()
    }
  #endif

  func testBufferDurationSurvivesFailedPlayerRecovery() throws {
    let firstAsset = WrapperLoadingAsset(url: trackURL)
    let nextAsset = WrapperLoadingAsset(url: trackURL)
    var assets = [firstAsset, nextAsset]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in assets.removeFirst() })
    wrapper.bufferDuration = 12
    wrapper.load(from: trackURL, playWhenReady: false)
    firstAsset.finishPlayable()
    drainMainQueue()
    let previousPlayer = wrapper.avPlayer
    wrapper.itemFailedToPlayToEndTime()

    wrapper.load()
    nextAsset.finishPlayable()
    drainMainQueue()

    XCTAssertFalse(wrapper.avPlayer === previousPlayer)
    XCTAssertEqual(wrapper.bufferDuration, 12)
    XCTAssertEqual(try XCTUnwrap(wrapper.currentItem).preferredForwardBufferDuration, 12)
    wrapper.unload()
  }

  func testInvalidSourceRetiresPreviousURLAndExplicitRetryPreservesFailure() {
    let replacementURL = URL(fileURLWithPath: "/yrt-tests/replacement.mp3")
    var loadedURLs: [URL] = []
    let wrapper = AVPlayerWrapper(makeAsset: { url, _ in
      loadedURLs.append(url)
      return WrapperLoadingAsset(url: url)
    })
    wrapper.load(from: trackURL, playWhenReady: false, options: ["previous": true])

    wrapper.load(from: "http://[", playWhenReady: true)
    wrapper.load()
    wrapper.play()

    XCTAssertEqual(loadedURLs, [trackURL])
    XCTAssertNil(wrapper.url)
    XCTAssertNil(wrapper.urlOptions)
    XCTAssertNil(wrapper.currentItem)
    XCTAssertEqual(wrapper.state, .failed)
    if case .invalidSourceUrl(let source)? = wrapper.playbackError {
      XCTAssertEqual(source, "http://[")
    } else {
      XCTFail("Retry must retain the invalid source failure")
    }

    wrapper.load(from: replacementURL, playWhenReady: false)

    XCTAssertEqual(loadedURLs, [trackURL, replacementURL])
    XCTAssertNil(wrapper.playbackError)
    XCTAssertEqual(wrapper.state, .loading)
    XCTAssertFalse(wrapper.playWhenReady)
    wrapper.unload()
  }

  func testReplacingInvalidSourceFromFailureStateReportsOnlyReplacementError() {
    let wrapper = AVPlayerWrapper()
    let delegate = WrapperCorrectnessDelegate()
    let replacementSource = "https://["
    wrapper.delegate = delegate
    delegate.onState = { [weak delegate] state in
      guard state == .failed else { return }
      delegate?.onState = nil
      wrapper.load(from: replacementSource)
    }

    wrapper.load(from: "http://[")

    XCTAssertEqual(delegate.failures, 1)
    guard case .invalidSourceUrl(let reportedSource)? = delegate.lastError as? AudioPlayerError.PlaybackError else {
      return XCTFail("Expected the replacement source error")
    }
    XCTAssertEqual(reportedSource, replacementSource)
  }

  func testInvalidSourceReplacesPreviousSourceFailure() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.itemFailedToPlayToEndTime()

    wrapper.load(from: "http://[", playWhenReady: false)

    XCTAssertEqual(wrapper.state, .failed)
    XCTAssertEqual(delegate.failures, 2)
    if case .invalidSourceUrl(let source)? = wrapper.playbackError {
      XCTAssertEqual(source, "http://[")
    } else {
      XCTFail("A new invalid source must report its own failure")
    }
    wrapper.unload()
  }

  func testFailureIsReportedOnceAcrossItemStatusAndEndNotification() {
    let wrapper = AVPlayerWrapper()
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate

    wrapper.itemFailedToPlayToEndTime()
    wrapper.itemFailedToPlayToEndTime()

    XCTAssertEqual(wrapper.state, .failed)
    XCTAssertEqual(delegate.failures + delegate.endFailures, 1)
  }

  func testExternalMidtrackPauseClearsIntentAndReportsPaused() {
    let wrapper = AVPlayerWrapper()
    let player = WrapperSeekingPlayer()
    let item = WrapperStatusItem(url: trackURL)
    let asset = WrapperLoadingAsset(url: trackURL)
    wrapper.avPlayer = player
    wrapper.asset = asset
    wrapper.item = item
    player.replaceCurrentItem(with: item)
    player.position = CMTime(seconds: 10, preferredTimescale: 1000)
    wrapper.playWhenReady = true
    wrapper.state = .playing

    wrapper.player(didChangeTimeControlStatus: .paused)

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testExternalLivePauseUsesItemTimelineInsteadOfSeekableWindowLength() {
    let wrapper = AVPlayerWrapper()
    let player = WrapperSeekingPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    asset.reportedDuration = .indefinite
    let item = WrapperStatusItem(asset: asset)
    item.reportedDuration = .indefinite
    item.reportedSeekableTimeRanges = [
      NSValue(
        timeRange: CMTimeRange(
          start: CMTime(seconds: 120, preferredTimescale: 1000),
          duration: CMTime(seconds: 30, preferredTimescale: 1000)
        ))
    ]
    wrapper.avPlayer = player
    wrapper.asset = asset
    wrapper.item = item
    player.replaceCurrentItem(with: item)
    player.position = CMTime(seconds: 140, preferredTimescale: 1000)
    wrapper.playWhenReady = true
    wrapper.state = .playing
    XCTAssertEqual(wrapper.duration, 30)

    wrapper.player(didChangeTimeControlStatus: .paused)

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testExternalPauseWithUnknownDurationClearsIntent() {
    for duration: CMTime in [.indefinite, .invalid, .zero] {
      let wrapper = AVPlayerWrapper()
      let player = WrapperSeekingPlayer()
      let asset = WrapperLoadingAsset(url: trackURL)
      asset.reportedDuration = duration
      let item = WrapperStatusItem(asset: asset)
      item.reportedDuration = duration
      wrapper.avPlayer = player
      wrapper.asset = asset
      wrapper.item = item
      player.replaceCurrentItem(with: item)
      player.position = CMTime(seconds: 10, preferredTimescale: 1000)
      wrapper.playWhenReady = true
      wrapper.state = .playing

      wrapper.player(didChangeTimeControlStatus: .paused)

      XCTAssertFalse(wrapper.playWhenReady)
      XCTAssertEqual(wrapper.state, .paused)
      wrapper.unload()
    }
  }

  func testNativePauseAtFiniteEndPreservesIntentForEndNotification() {
    let wrapper = AVPlayerWrapper()
    let player = WrapperSeekingPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let item = WrapperStatusItem(asset: asset)
    wrapper.avPlayer = player
    wrapper.asset = asset
    wrapper.item = item
    player.replaceCurrentItem(with: item)
    player.position = CMTime(seconds: 60, preferredTimescale: 1000)
    wrapper.playWhenReady = true
    wrapper.state = .playing

    wrapper.player(didChangeTimeControlStatus: .paused)

    XCTAssertTrue(wrapper.playWhenReady)
    wrapper.unload()
  }

  func testBufferedRangeChangesDoNotPublishEpisodeDuration() {
    let item = WrapperStatusItem(url: trackURL)
    let observer = AVPlayerItemObserver()
    let delegate = WrapperItemObserverDelegate()
    observer.delegate = delegate
    observer.startObserving(item: item)

    item.reportLoadedTimeRanges([
      NSValue(
        timeRange: CMTimeRange(
          start: CMTime(seconds: 120, preferredTimescale: 1000),
          duration: CMTime(seconds: 10, preferredTimescale: 1000)
        ))
    ])

    XCTAssertTrue(delegate.durations.isEmpty)
    item.reportDuration(CMTime(seconds: 3600, preferredTimescale: 1000))
    XCTAssertEqual(delegate.durations, [3600])
    observer.stopObservingCurrentItem()
  }

  func testBackgroundPauseCannotOverrideNewerPlayIntentBeforeNativeStatusCatchesUp() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    runOnBackgroundAndWaitForCompletion {
      player.reportTimeControlStatus(.paused)
    }

    wrapper.play()
    drainMainQueue()

    XCTAssertEqual(player.timeControlStatus, .paused)
    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .playing)
    wrapper.unload()
  }

  private func makePlayingStallFixture() -> (
    wrapper: AVPlayerWrapper, player: WrapperControlledSeekingPlayer, item: WrapperStatusItem
  ) {
    let player = WrapperControlledSeekingPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let item = WrapperStatusItem(asset: asset)
    let wrapper = AVPlayerWrapper(
      player: player, makeAsset: { _, _ in asset }, makePlayerItem: { _, _ in item })
    wrapper.automaticallyWaitsToMinimizeStalling = false
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    return (wrapper, player, item)
  }

  func testBackgroundManualStallBurstResumesAfterBufferRefillsBeforeMainQueueDrains() {
    for postsStalledNotification in [false, true] {
      for likelyToKeepUpArrivesFirst in [false, true] {
        let (wrapper, player, item) = makePlayingStallFixture()
        wrapper.rate = 1.75

        runOnBackgroundAndWaitForCompletion {
          item.reportPlaybackBufferEmpty(true)
          player.reportTimeControlStatus(.paused)
          if postsStalledNotification {
            NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
          }
          if likelyToKeepUpArrivesFirst {
            item.reportPlaybackLikelyToKeepUp(true)
            item.reportPlaybackBufferEmpty(false)
          } else {
            item.reportPlaybackBufferEmpty(false)
            item.reportPlaybackLikelyToKeepUp(true)
          }
        }
        drainMainQueue()

        XCTAssertTrue(wrapper.playWhenReady)
        XCTAssertEqual(player.rate, 1.75)
        XCTAssertEqual(wrapper.state, .ready)
        wrapper.unload()
      }
    }
  }

  func testExplicitPauseSupersedesQueuedStarvationAndRecovery() {
    let (wrapper, player, item) = makePlayingStallFixture()
    runOnBackgroundAndWaitForCompletion {
      item.reportPlaybackBufferEmpty(true)
      player.reportTimeControlStatus(.paused)
      item.reportPlaybackBufferEmpty(false)
      item.reportPlaybackLikelyToKeepUp(true)
    }

    wrapper.pause()
    let startsAfterPause = player.startedItems.count
    drainMainQueue()

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(player.startedItems.count, startsAfterPause)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testNewPlaySupersedesQueuedStarvationForTheSameItem() {
    let (wrapper, player, item) = makePlayingStallFixture()
    runOnBackgroundAndWaitForCompletion {
      item.reportPlaybackBufferEmpty(true)
      player.reportTimeControlStatus(.paused)
      item.reportPlaybackBufferEmpty(false)
      item.reportPlaybackLikelyToKeepUp(true)
    }

    wrapper.pause()
    wrapper.play()
    let startsAfterPlay = player.startedItems.count
    drainMainQueue()

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 1)
    XCTAssertEqual(player.startedItems.count, startsAfterPlay)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testExplicitPlayResumesExistingStallWhenRefillCallbacksAreStillQueued() {
    let (wrapper, player, item) = makePlayingStallFixture()
    item.reportPlaybackBufferEmpty(true)
    player.reportTimeControlStatus(.paused)
    XCTAssertEqual(wrapper.state, .buffering)
    runOnBackgroundAndWaitForCompletion {
      item.reportPlaybackBufferEmpty(false)
      item.reportPlaybackLikelyToKeepUp(true)
    }

    wrapper.play()
    drainMainQueue()

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 1)
    XCTAssertEqual(wrapper.state, .ready)
    wrapper.unload()
  }

  func testReplacementSourceSupersedesQueuedStarvationAndRecovery() {
    let player = WrapperControlledSeekingPlayer()
    let firstAsset = WrapperLoadingAsset(url: trackURL)
    let replacementAsset = WrapperLoadingAsset(url: trackURL)
    let firstItem = WrapperStatusItem(asset: firstAsset)
    let replacementItem = WrapperStatusItem(asset: replacementAsset)
    var assets = [firstAsset, replacementAsset]
    var items = [firstItem, replacementItem]
    let wrapper = AVPlayerWrapper(
      player: player, makeAsset: { _, _ in assets.removeFirst() },
      makePlayerItem: { _, _ in items.removeFirst() })
    wrapper.automaticallyWaitsToMinimizeStalling = false
    wrapper.load(from: trackURL, playWhenReady: true)
    firstAsset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    runOnBackgroundAndWaitForCompletion {
      firstItem.reportPlaybackBufferEmpty(true)
      player.reportTimeControlStatus(.paused)
      firstItem.reportPlaybackBufferEmpty(false)
      firstItem.reportPlaybackLikelyToKeepUp(true)
    }

    wrapper.load(from: trackURL, playWhenReady: false)
    replacementAsset.finishPlayable()
    drainMainQueue()

    XCTAssertTrue(wrapper.currentItem === replacementItem)
    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)
    XCTAssertFalse(player.startedItems.contains { $0 === replacementItem })
    wrapper.unload()
  }

  func testBackgroundNativePauseWithoutStarvationStillClearsPlayIntent() {
    let (wrapper, player, item) = makePlayingStallFixture()
    runOnBackgroundAndWaitForCompletion {
      player.reportTimeControlStatus(.paused)
      item.reportPlaybackLikelyToKeepUp(true)
    }
    drainMainQueue()

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testManualBufferStallKeepsIntentAndResumesCurrentRateWhenBufferRecovers() {
    for notificationComesFirst in [false, true] {
      let (wrapper, player, item) = makePlayingStallFixture()
      item.reportPlaybackBufferEmpty(true)
      if notificationComesFirst {
        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
      }
      player.reportTimeControlStatus(.paused)
      if !notificationComesFirst {
        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
      }
      wrapper.rate = 1.75

      XCTAssertTrue(wrapper.playWhenReady)
      XCTAssertEqual(wrapper.state, .buffering)
      XCTAssertEqual(player.rate, 0)

      item.reportPlaybackBufferEmpty(false)
      item.reportPlaybackLikelyToKeepUp(true)

      XCTAssertTrue(wrapper.playWhenReady)
      XCTAssertEqual(player.rate, 1.75)
      wrapper.unload()
    }
  }

  func testStallRecoveryWaitsForEmptyBufferToClearAfterLikelyToKeepUpArrives() {
    let (wrapper, player, item) = makePlayingStallFixture()
    item.reportPlaybackBufferEmpty(true)
    player.reportTimeControlStatus(.paused)
    NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)

    item.reportPlaybackLikelyToKeepUp(true)

    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(wrapper.state, .buffering)

    item.reportPlaybackBufferEmpty(false)

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 1)
    wrapper.unload()
  }

  func testManualBufferStallResumesWhenBufferIsFullWithoutLikelyToKeepUp() {
    let (wrapper, player, item) = makePlayingStallFixture()
    item.reportPlaybackBufferEmpty(true)
    player.reportTimeControlStatus(.paused)
    item.reportPlaybackBufferEmpty(false)

    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(wrapper.state, .buffering)
    XCTAssertFalse(item.isPlaybackLikelyToKeepUp)

    item.reportPlaybackBufferFull(true)

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 1)
    wrapper.unload()
  }

  func testStallRecoveryStateDelegateCanPauseOrReplaceSourceBeforePlaybackRestarts() {
    for replacesSource in [false, true] {
      let (wrapper, player, item) = makePlayingStallFixture()
      item.reportPlaybackBufferEmpty(true)
      player.reportTimeControlStatus(.paused)
      NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
      let startsBeforeRecovery = player.startedItems.count
      let delegate = WrapperCorrectnessDelegate()
      delegate.onState = { state in
        guard state == .ready else { return }
        if replacesSource {
          wrapper.load(from: self.trackURL, playWhenReady: false)
        } else {
          wrapper.pause()
        }
      }
      wrapper.delegate = delegate

      item.reportPlaybackBufferEmpty(false)
      item.reportPlaybackLikelyToKeepUp(true)

      XCTAssertFalse(wrapper.playWhenReady)
      XCTAssertEqual(player.rate, 0)
      XCTAssertEqual(player.startedItems.count, startsBeforeRecovery)
      if replacesSource { XCTAssertNil(wrapper.currentItem) }
      wrapper.unload()
    }
  }

  func testExplicitPauseWhileBufferingPreventsAutomaticStallResume() {
    let (wrapper, player, item) = makePlayingStallFixture()
    item.reportPlaybackBufferEmpty(true)
    player.reportTimeControlStatus(.paused)
    NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
    let startsBeforePause = player.startedItems.count

    wrapper.pause()
    item.reportPlaybackBufferEmpty(false)
    item.reportPlaybackLikelyToKeepUp(true)

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(player.startedItems.count, startsBeforePause)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testRetiredStalledItemCannotResumeReplacementSource() {
    let player = WrapperControlledSeekingPlayer()
    let firstAsset = WrapperLoadingAsset(url: trackURL)
    let replacementAsset = WrapperLoadingAsset(url: trackURL)
    let firstItem = WrapperStatusItem(asset: firstAsset)
    let replacementItem = WrapperStatusItem(asset: replacementAsset)
    var assets = [firstAsset, replacementAsset]
    var items = [firstItem, replacementItem]
    let wrapper = AVPlayerWrapper(
      player: player, makeAsset: { _, _ in assets.removeFirst() },
      makePlayerItem: { _, _ in items.removeFirst() })
    wrapper.automaticallyWaitsToMinimizeStalling = false
    wrapper.load(from: trackURL, playWhenReady: true)
    firstAsset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    firstItem.reportPlaybackBufferEmpty(true)
    player.reportTimeControlStatus(.paused)
    NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: firstItem)

    wrapper.load(from: trackURL, playWhenReady: false)
    replacementAsset.finishPlayable()
    drainMainQueue()
    firstItem.reportPlaybackBufferEmpty(false)
    firstItem.reportPlaybackLikelyToKeepUp(true)
    NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: firstItem)

    XCTAssertTrue(wrapper.currentItem === replacementItem)
    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)
    XCTAssertFalse(player.startedItems.contains { $0 === replacementItem })
    wrapper.unload()
  }

  func testEndOfItemCannotBecomeRecoverableBufferStarvation() {
    let (wrapper, player, item) = makePlayingStallFixture()
    player.reportPosition(60)
    let startsBeforeEnd = player.startedItems.count

    item.reportPlaybackBufferEmpty(true)
    player.reportTimeControlStatus(.paused)
    NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
    item.reportPlaybackBufferEmpty(false)
    item.reportPlaybackLikelyToKeepUp(true)

    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(player.startedItems.count, startsBeforeEnd)
    XCTAssertNotEqual(wrapper.state, .buffering)
    wrapper.unload()
  }

  func testNativePauseWithNonemptyManualBufferStillClearsPlayIntent() {
    let (wrapper, player, item) = makePlayingStallFixture()
    XCTAssertFalse(item.isPlaybackBufferEmpty)

    player.reportTimeControlStatus(.paused)
    item.reportPlaybackLikelyToKeepUp(true)

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    XCTAssertEqual(player.rate, 0)
    wrapper.unload()
  }

  #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    func testInterruptionDuringBufferStarvationBlocksRecoveryUntilExplicitPlay() {
      let (wrapper, player, item) = makePlayingStallFixture()
      item.reportPlaybackBufferEmpty(true)
      player.reportTimeControlStatus(.paused)
      NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
      let startsBeforeInterruption = player.startedItems.count

      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: nil,
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
      item.reportPlaybackBufferEmpty(false)
      item.reportPlaybackLikelyToKeepUp(true)

      XCTAssertTrue(wrapper.playWhenReady)
      XCTAssertEqual(player.rate, 0)
      XCTAssertEqual(player.startedItems.count, startsBeforeInterruption)

      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: nil,
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
        ])

      XCTAssertEqual(player.rate, 0)
      wrapper.play()
      XCTAssertEqual(player.rate, 1)
      wrapper.unload()
    }

    func testToggleRestartsPausedPlaybackAfterAnInterruption() {
      let (wrapper, player, _) = makePlayingStallFixture()
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: nil,
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
      player.reportTimeControlStatus(.paused)
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: nil,
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
        ])
      XCTAssertEqual(wrapper.state, .paused)
      XCTAssertEqual(player.rate, 0)

      wrapper.togglePlaying()

      XCTAssertTrue(wrapper.playWhenReady)
      XCTAssertEqual(player.rate, 1)
      wrapper.unload()
    }

    func testLateBufferEventsAfterInterruptionEndsCannotGrantResumePermission() {
      let (wrapper, player, item) = makePlayingStallFixture()
      item.reportPlaybackBufferEmpty(true)
      player.reportTimeControlStatus(.paused)
      NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: nil,
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: nil,
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
        ])
      let startsBeforeLateEvents = player.startedItems.count

      item.reportPlaybackBufferEmpty(true)
      player.reportTimeControlStatus(.paused)
      item.reportPlaybackLikelyToKeepUp(true)
      item.reportPlaybackBufferEmpty(false)

      XCTAssertTrue(wrapper.playWhenReady)
      XCTAssertEqual(player.rate, 0)
      XCTAssertEqual(player.startedItems.count, startsBeforeLateEvents)
      wrapper.unload()
    }

    func testExplicitPauseDuringInterruptedStallPreventsBufferRecoveryFromRestarting() {
      let (wrapper, player, item) = makePlayingStallFixture()
      item.reportPlaybackBufferEmpty(true)
      player.reportTimeControlStatus(.paused)
      NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: nil,
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])

      wrapper.pause()
      item.reportPlaybackBufferEmpty(false)
      item.reportPlaybackLikelyToKeepUp(true)
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification, object: nil,
        userInfo: [
          AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
        ])

      XCTAssertFalse(wrapper.playWhenReady)
      XCTAssertEqual(player.rate, 0)
      wrapper.unload()
    }

    func testHeadphoneDisconnectDuringStallPreventsBufferRecoveryFromRestarting() {
      let (wrapper, player, item) = makePlayingStallFixture()
      item.reportPlaybackBufferEmpty(true)
      player.reportTimeControlStatus(.paused)
      NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)

      NotificationCenter.default.post(
        name: AVAudioSession.routeChangeNotification, object: nil,
        userInfo: [
          AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable
            .rawValue
        ])
      item.reportPlaybackBufferEmpty(false)
      item.reportPlaybackLikelyToKeepUp(true)

      XCTAssertFalse(wrapper.playWhenReady)
      XCTAssertEqual(player.rate, 0)
      XCTAssertEqual(wrapper.state, .paused)
      wrapper.unload()
    }

    func testQueuedInterruptionCannotOverrideNewerPlayOrSource() {
      for replacesSource in [false, true] {
        let (wrapper, player, _) = makePlayingStallFixture()
        runOnBackgroundAndWaitForCompletion {
          NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
              AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ])
          NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
              AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            ])
        }
        if replacesSource {
          wrapper.load(from: trackURL, playWhenReady: true)
        } else {
          wrapper.play()
        }
        drainMainQueue()

        XCTAssertTrue(wrapper.playWhenReady)
        XCTAssertEqual(player.rate, 1)
        wrapper.unload()
      }
    }

    func testQueuedHeadphoneDisconnectCannotOverrideNewerPlayOrSource() {
      for replacesSource in [false, true] {
        let (wrapper, player, item) = makePlayingStallFixture()
        item.reportPlaybackBufferEmpty(true)
        player.reportTimeControlStatus(.paused)
        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
        runOnBackgroundAndWaitForCompletion {
          NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [
              AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason
                .oldDeviceUnavailable
                .rawValue
            ])
        }
        if replacesSource {
          wrapper.load(from: trackURL, playWhenReady: true)
        } else {
          wrapper.play()
        }
        drainMainQueue()

        XCTAssertTrue(wrapper.playWhenReady)
        wrapper.unload()
      }
    }
  #endif

  func testExternalPauseAtZeroAfterPlaybackStartedClearsIntent() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    player.reportPosition(0)

    runOnBackgroundAndWaitForCompletion {
      player.reportTimeControlStatus(.paused)
    }
    drainMainQueue()

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testInitialPauseAtZeroDoesNotCancelPendingAutoplay() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()

    player.reportTimeControlStatus(.paused)

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .loading)
    wrapper.unload()
  }

  func testBackgroundWaitingThenPauseAtZeroBeforeMainDeliveryClearsIntent() {
    let player = WrapperManualItemTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()

    runOnBackgroundAndWaitForCompletion {
      player.reportTimeControlStatus(.waitingToPlayAtSpecifiedRate)
      player.reportTimeControlStatus(.paused)
    }
    drainMainQueue()

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    XCTAssertFalse(delegate.states.contains(.buffering))
    wrapper.unload()
  }

  func testBackgroundPlayingThenPauseAtZeroBeforeMainDeliveryClearsIntent() {
    let player = WrapperManualItemTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()

    runOnBackgroundAndWaitForCompletion {
      player.reportTimeControlStatus(.playing)
      player.reportPosition(0)
      player.reportTimeControlStatus(.paused)
    }
    drainMainQueue()

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    XCTAssertFalse(delegate.states.contains(.playing))
    wrapper.unload()
  }

  func testExternalPauseAtZeroDuringBufferingClearsIntentAfterTransportAcceptedPlayback() {
    for becomesReady in [false, true] {
      let player = WrapperTransportPlayer()
      let asset = WrapperLoadingAsset(url: trackURL)
      let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
      wrapper.load(from: trackURL, playWhenReady: true)
      asset.finishPlayable()
      drainMainQueue()
      player.reportTimeControlStatus(.waitingToPlayAtSpecifiedRate)
      if becomesReady { wrapper.item(statusDidChange: .readyToPlay) }
      XCTAssertEqual(wrapper.state, becomesReady ? .ready : .buffering)
      XCTAssertEqual(wrapper.currentTime, 0)

      runOnBackgroundAndWaitForCompletion {
        player.reportTimeControlStatus(.paused)
      }
      drainMainQueue()

      XCTAssertFalse(wrapper.playWhenReady)
      XCTAssertEqual(wrapper.state, .paused)
      wrapper.unload()
    }
  }

  func testReplacementSourceDoesNotInheritAcceptedPlaybackAtZero() {
    let player = WrapperTransportPlayer()
    let first = WrapperLoadingAsset(url: trackURL)
    let replacement = WrapperLoadingAsset(url: trackURL)
    var assets = [first, replacement]
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: true)
    first.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.waitingToPlayAtSpecifiedRate)

    wrapper.load(from: trackURL, playWhenReady: true)
    player.reportTimeControlStatus(.paused)

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .loading)
    wrapper.unload()
  }

  func testExternalPauseAtZeroWhenWaitingBeganBeforeItemInstallation() {
    let player = WrapperManualItemTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    player.reportTimeControlStatus(.waitingToPlayAtSpecifiedRate)
    XCTAssertNil(wrapper.currentItem)
    asset.finishPlayable()
    drainMainQueue()
    XCTAssertEqual(player.timeControlStatus, .waitingToPlayAtSpecifiedRate)

    player.reportTimeControlStatus(.paused)

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testReplacementInstalledAtZeroDoesNotInheritRetiredAcceptance() {
    let player = WrapperManualItemTransportPlayer()
    let first = WrapperLoadingAsset(url: trackURL)
    let replacement = WrapperLoadingAsset(url: trackURL)
    var assets = [first, replacement]
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: true)
    first.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.waitingToPlayAtSpecifiedRate)

    wrapper.load(from: trackURL, playWhenReady: true)
    player.reportTimeControlStatus(.paused)
    replacement.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.paused)

    XCTAssertNotNil(wrapper.currentItem)
    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .loading)
    wrapper.unload()
  }

  func testWaitingCaptureSpanningRetirementCannotAcceptReplacementWithoutItem() {
    let player = WrapperManualItemTransportPlayer()
    let first = WrapperLoadingAsset(url: trackURL)
    let replacement = WrapperLoadingAsset(url: trackURL)
    var assets = [first, replacement]
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: true)
    first.finishPlayable()
    drainMainQueue()
    let capturedItem = DispatchSemaphore(value: 0)
    let resumeCapture = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    player.onCurrentItemRead = {
      guard !Thread.isMainThread else { return }
      capturedItem.signal()
      XCTAssertEqual(resumeCapture.wait(timeout: .now() + 3), .success)
    }
    DispatchQueue.global().async {
      player.reportTimeControlStatus(.waitingToPlayAtSpecifiedRate)
      completed.signal()
    }
    XCTAssertEqual(capturedItem.wait(timeout: .now() + 3), .success)

    wrapper.load(from: trackURL, playWhenReady: true)
    resumeCapture.signal()
    XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
    player.onCurrentItemRead = nil
    player.reportTimeControlStatus(.paused)
    drainMainQueue()

    XCTAssertNil(wrapper.currentItem)
    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .loading)
    wrapper.unload()
  }

  func testBackgroundPlayingCannotOverrideNewerPauseIntentBeforeNativeStatusCatchesUp() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    runOnBackgroundAndWaitForCompletion {
      player.reportTimeControlStatus(.playing)
    }

    wrapper.pause()
    drainMainQueue()

    XCTAssertEqual(player.timeControlStatus, .playing)
    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .loading)
    wrapper.unload()
  }

  func testBackgroundPauseAgreeingWithNewerPauseIntentStillReportsPaused() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    runOnBackgroundAndWaitForCompletion { player.reportTimeControlStatus(.paused) }

    wrapper.pause()
    drainMainQueue()

    XCTAssertEqual(player.timeControlStatus, .paused)
    XCTAssertEqual(player.rate, 0)
    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    XCTAssertEqual(delegate.states.last, .paused)
    wrapper.unload()
  }

  func testBackgroundPlayingAgreeingWithNewerPlayIntentStillReportsPlaying() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    runOnBackgroundAndWaitForCompletion { player.reportTimeControlStatus(.playing) }

    wrapper.play()
    drainMainQueue()

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .playing)
    wrapper.unload()
  }

  func testBackgroundPlayingFromRetiredEmptySourceCannotOverrideReplacementLoadingState() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.play()
    XCTAssertNil(wrapper.currentItem)
    runOnBackgroundAndWaitForCompletion { player.reportTimeControlStatus(.playing) }

    wrapper.load(from: trackURL, playWhenReady: true)
    drainMainQueue()

    XCTAssertNil(wrapper.currentItem)
    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .loading)
    wrapper.unload()
  }

  func testBackgroundPauseCannotOverrideNewerNativePlayingObservation() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    runOnBackgroundAndWaitForCompletion {
      player.reportTimeControlStatus(.paused)
    }

    player.reportTimeControlStatus(.playing)
    drainMainQueue()

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .playing)
    wrapper.unload()
  }

  func testCurrentBackgroundPauseStillClearsIntentAndReportsPaused() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)

    runOnBackgroundAndWaitForCompletion {
      player.reportTimeControlStatus(.paused)
    }
    drainMainQueue()

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testExternalPauseDelegatePlayPreservesNewerPlayingIntent() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    let delegate = WrapperCorrectnessDelegate()
    delegate.onPlayWhenReady = { playWhenReady in
      if !playWhenReady { wrapper.play() }
    }
    wrapper.delegate = delegate

    player.reportTimeControlStatus(.paused)

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .playing)
    delegate.onPlayWhenReady = nil
    wrapper.unload()
  }

  func testPausedObservationWithNonzeroDesiredRateCannotCancelNewPlay() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    wrapper.play()

    player.reportTimeControlStatus(.paused, rate: 1)

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .playing)
    player.reportTimeControlStatus(.playing, rate: 1)
    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .playing)
    wrapper.unload()
  }

  func testPlayingObservationWithZeroDesiredRateCannotRevivePausedState() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    wrapper.pause()
    player.reportTimeControlStatus(.paused)
    XCTAssertEqual(wrapper.state, .paused)

    player.reportTimeControlStatus(.playing, rate: 0)

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testExternalPauseDelegateLoadPreservesNewerSourceLoadingState() {
    let player = WrapperTransportPlayer()
    let firstAsset = WrapperLoadingAsset(url: trackURL)
    let nextAsset = WrapperLoadingAsset(url: trackURL)
    var assets = [firstAsset, nextAsset]
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: true)
    firstAsset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    let delegate = WrapperCorrectnessDelegate()
    delegate.onPlayWhenReady = { playWhenReady in
      if !playWhenReady { wrapper.load(from: self.trackURL, playWhenReady: false) }
    }
    wrapper.delegate = delegate

    player.reportTimeControlStatus(.paused)

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .loading)
    XCTAssertTrue(wrapper.asset === nextAsset)
    delegate.onPlayWhenReady = nil
    wrapper.unload()
  }

  func testBackgroundFailureStillArrivesAfterNewerSeek() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    runOnBackgroundAndWaitForCompletion { player.reportFailure() }

    wrapper.seek(to: 7)
    drainMainQueue()

    XCTAssertEqual(wrapper.state, .failed)
    XCTAssertEqual(delegate.failures, 1)
    wrapper.unload()
  }

  func testBackgroundEndIsDroppedAfterNewerSeekOnSamePlayingItem() throws {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    let item = try XCTUnwrap(wrapper.currentItem)
    runOnBackgroundAndWaitForCompletion {
      NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    }

    wrapper.seek(to: 7)
    drainMainQueue()

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(delegate.ended, 0)
    runOnBackgroundAndWaitForCompletion {
      NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    }
    drainMainQueue()
    XCTAssertEqual(delegate.ended, 1)
    wrapper.unload()
  }

  func testBackgroundEndFailureStillArrivesAfterNewerSeek() throws {
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    let item = try XCTUnwrap(wrapper.currentItem)
    runOnBackgroundAndWaitForCompletion {
      NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
    }

    wrapper.seek(to: 7)
    drainMainQueue()

    XCTAssertEqual(wrapper.state, .failed)
    XCTAssertEqual(delegate.failures, 1)
    wrapper.unload()
  }

  func testBackgroundEndSurvivesRateChangeForSameItem() throws {
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    let item = try XCTUnwrap(wrapper.currentItem)
    runOnBackgroundAndWaitForCompletion {
      NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    }

    wrapper.rate = 1.5
    drainMainQueue()

    XCTAssertEqual(delegate.ended, 1)
    wrapper.unload()
  }

  func testBackgroundExternalPauseSurvivesSeekWithoutNewPlayIntent() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    runOnBackgroundAndWaitForCompletion { player.reportTimeControlStatus(.paused) }

    wrapper.seek(to: 7)
    drainMainQueue()

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testBackgroundPlayingSurvivesRateChangeWithoutNewPlayIntent() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    runOnBackgroundAndWaitForCompletion { player.reportTimeControlStatus(.playing) }

    wrapper.rate = 1.5
    drainMainQueue()

    XCTAssertEqual(wrapper.state, .playing)
    wrapper.unload()
  }

  func testRateChangeDoesNotResumePendingExternalPause() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    runOnBackgroundAndWaitForCompletion { player.reportTimeControlStatus(.paused) }
    XCTAssertEqual(player.rate, 0)

    wrapper.rate = 1.5

    XCTAssertEqual(player.rate, 0)
    drainMainQueue()
    XCTAssertEqual(wrapper.rate, 1.5)
    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .paused)
    wrapper.unload()
  }

  func testRateChangeUpdatesAlreadyPlayingNativeTransport() {
    let player = WrapperTransportPlayer()
    let wrapper = AVPlayerWrapper(player: player)
    wrapper.play()
    player.reportTimeControlStatus(.playing)

    wrapper.rate = 1.5

    XCTAssertEqual(player.rate, 1.5)
    XCTAssertTrue(wrapper.playWhenReady)
  }

  func testBackgroundPlayingSurvivesSeekWithoutNewPlayIntent() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    runOnBackgroundAndWaitForCompletion { player.reportTimeControlStatus(.playing) }

    wrapper.seek(to: 7)
    drainMainQueue()

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(wrapper.state, .playing)
    wrapper.unload()
  }

  func testInitialPausedItemBecomesReadyWhenItemStatusIsReady() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    asset.finishPlayable()
    drainMainQueue()

    player.reportTimeControlStatus(.paused)
    wrapper.item(didUpdatePlaybackLikelyToKeepUp: true)
    XCTAssertEqual(wrapper.state, .loading)

    wrapper.item(statusDidChange: .readyToPlay)
    player.reportTimeControlStatus(.paused)

    XCTAssertEqual(wrapper.state, .ready)
    XCTAssertEqual(delegate.states.filter { $0 == .ready }.count, 1)
    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)
    wrapper.unload()
  }

  func testLateReadinessDoesNotReplaceExplicitPause() {
    let player = WrapperTransportPlayer()
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    wrapper.item(statusDidChange: .readyToPlay)
    player.reportTimeControlStatus(.playing)
    wrapper.pause()
    player.reportTimeControlStatus(.paused)
    XCTAssertEqual(wrapper.state, .paused)

    wrapper.item(statusDidChange: .readyToPlay)
    wrapper.item(didUpdatePlaybackLikelyToKeepUp: true)

    XCTAssertEqual(wrapper.state, .paused)
    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)
    wrapper.unload()
  }

  func testLateReadinessDoesNotReviveTerminalPlaybackStates() {
    for state in [AVPlayerWrapperState.failed, .ended, .stopped] {
      let wrapper = AVPlayerWrapper()
      wrapper.state = state

      wrapper.item(statusDidChange: .readyToPlay)
      wrapper.item(didUpdatePlaybackLikelyToKeepUp: true)

      XCTAssertEqual(wrapper.state, state)
    }
  }

  func testStateDelegateCanSynchronouslyReadStateOnAnotherQueue() {
    let wrapper = AVPlayerWrapper()
    let delegate = WrapperCorrectnessDelegate()
    let callback = expectation(description: "state callback returns")
    let readQueue = DispatchQueue(label: "SwiftAudioExWrapperCorrectnessTests.stateRead")
    var readTimedOut = false
    delegate.onState = { state in
      guard state == .playing else { return }
      let completed = DispatchSemaphore(value: 0)
      readQueue.async {
        XCTAssertEqual(wrapper.state, .playing)
        completed.signal()
      }
      readTimedOut = completed.wait(timeout: .now() + 1) == .timedOut
      callback.fulfill()
    }
    wrapper.delegate = delegate

    wrapper.state = .playing
    wait(for: [callback], timeout: 3)

    XCTAssertFalse(readTimedOut, "State delegates must run after the state lock is released")
    XCTAssertEqual(wrapper.state, .playing)
  }

  func testItemFailureIsObservedOnMainAndRetiredItemFailureIsDropped() {
    let observer = AVPlayerItemObserver()
    let delegate = WrapperItemObserverDelegate()
    let oldItem = WrapperStatusItem(url: trackURL)
    let nextItem = WrapperStatusItem(url: trackURL)
    let background = DispatchQueue(label: "SwiftAudioExWrapperCorrectnessTests.itemFailure")
    observer.delegate = delegate
    observer.startObserving(item: oldItem)
    runOnBackgroundAndWaitForCompletion { oldItem.fail() }
    observer.startObserving(item: nextItem)
    drainMainQueue()
    XCTAssertEqual(delegate.failures, 0)
    let failed = expectation(description: "current item failure arrives on main")
    delegate.onFailure = { failed.fulfill() }

    background.async { nextItem.fail() }
    wait(for: [failed], timeout: 3)

    XCTAssertEqual(delegate.failures, 1)
    observer.stopObservingCurrentItem()
  }

  func testBackgroundEndNotificationIsDeliveredOnMainAndDroppedAfterReplacement() {
    let observer = AVPlayerItemNotificationObserver()
    let delegate = WrapperNotificationDelegate()
    let oldItem = AVPlayerItem(url: trackURL)
    let nextItem = AVPlayerItem(url: trackURL)
    let background = DispatchQueue(label: "SwiftAudioExWrapperCorrectnessTests.notification")
    observer.delegate = delegate
    observer.startObserving(item: oldItem)
    runOnBackgroundAndWaitForCompletion {
      NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
    }
    observer.startObserving(item: nextItem)
    drainMainQueue()
    XCTAssertEqual(delegate.ended, 0)
    let ended = expectation(description: "current item end arrives on main")
    delegate.onEnd = { ended.fulfill() }

    background.async {
      NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: nextItem)
    }
    wait(for: [ended], timeout: 3)

    XCTAssertEqual(delegate.ended, 1)
    observer.stopObservingCurrentItem()
  }
}

final class SwiftAudioExWrapperSeekCompletionTests: XCTestCase {
  private let trackURL = URL(fileURLWithPath: "/yrt-tests/completion-track.mp3")

  private func drainMainQueue() {
    let drained = expectation(description: "seek completions finish")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  func testNegativeSeekSubmitsAndPublishesZeroWithOwnedCompletion() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    asset.finishPlayable()
    drainMainQueue()
    var results: [Bool] = []

    wrapper.seek(to: -10, completionHandler: { results.append($0) })

    XCTAssertEqual(player.targets, [0])
    XCTAssertTrue(results.isEmpty)
    player.completions[0](true)
    drainMainQueue()
    XCTAssertEqual(delegate.seeks, [0])
    XCTAssertEqual(delegate.seekOutcomes, [true])
    XCTAssertEqual(results, [true])
    wrapper.unload()
  }

  func testRelativeBackwardSeekBeforeStartSubmitsAndPublishesZero() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    asset.finishPlayable()
    drainMainQueue()
    player.position = CMTime(seconds: 5, preferredTimescale: 1000)

    wrapper.seek(by: -15)

    XCTAssertEqual(player.targets, [0])
    player.completions[0](true)
    drainMainQueue()
    XCTAssertEqual(delegate.seeks, [0])
    wrapper.unload()
  }

  func testDeferredRelativeSeekUsesNormalizedPendingTarget() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false, initialTime: 5)

    wrapper.seek(by: -15)
    wrapper.seek(by: 7)
    asset.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.targets, [7])
    player.completions[0](true)
    drainMainQueue()
    XCTAssertEqual(delegate.seeks, [7])
    wrapper.unload()
  }

  func testNegativeInitialTimeIsNormalizedBeforeRelativeSeek() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false, initialTime: -10)

    wrapper.seek(by: 7)
    asset.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.targets, [7])
    player.completions[0](true)
    drainMainQueue()
    XCTAssertEqual(delegate.seeks, [7])
    wrapper.unload()
  }

  func testSeekWaitsForNativeCompletionAndCompletesOnMain() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: false)
    asset.finishPlayable()
    drainMainQueue()
    var results: [Bool] = []
    wrapper.seek(
      to: 8,
      completionHandler: {
        XCTAssertTrue(Thread.isMainThread)
        results.append($0)
      })
    XCTAssertTrue(results.isEmpty)

    runOnBackgroundAndWaitForCompletion { player.completions[0](true) }
    drainMainQueue()

    XCTAssertEqual(results, [true])
    wrapper.unload()
  }

  func testReplacementCancelsSeekExactlyOnceAndLateSuccessCannotPublish() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    asset.finishPlayable()
    drainMainQueue()
    var results: [Bool] = []
    wrapper.seek(
      to: 8,
      completionHandler: {
        XCTAssertTrue(Thread.isMainThread)
        results.append($0)
      })

    wrapper.unload()
    player.completions[0](true)
    drainMainQueue()

    XCTAssertEqual(results, [false])
    XCTAssertEqual(delegate.seeks, [8])
    XCTAssertEqual(delegate.seekOutcomes, [false])
  }

  func testSupersededInFlightSeekPublishesCancellationBeforeReplacementSuccess() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    asset.finishPlayable()
    drainMainQueue()

    wrapper.seek(to: 8)
    wrapper.seek(to: 12)
    player.completions[0](true)
    player.completions[1](true)
    drainMainQueue()

    XCTAssertEqual(delegate.seeks, [8, 12])
    XCTAssertEqual(delegate.seekOutcomes, [false, true])
    wrapper.unload()
  }

  func testSeekDelegateStartingNewSeekSupersedesPreviousCompletion() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    asset.finishPlayable()
    drainMainQueue()
    var results: [String] = []
    delegate.onSeek = { seconds in
      if seconds == 8 {
        wrapper.seek(to: 12, completionHandler: { results.append("new:\($0)") })
      }
    }
    wrapper.seek(to: 8, completionHandler: { results.append("old:\($0)") })

    player.completions[0](true)
    drainMainQueue()
    XCTAssertEqual(results, ["old:false"])
    player.completions[1](true)
    drainMainQueue()

    XCTAssertEqual(results, ["old:false", "new:true"])
    XCTAssertEqual(delegate.seeks, [8, 12])
    wrapper.unload()
  }

  func testSeekSupersededDuringPlaybackRestartDoesNotPublishStaleSuccess() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: true)
    var results: [Bool] = []
    wrapper.seek(to: 8, completionHandler: { results.append($0) })
    asset.finishPlayable()
    drainMainQueue()
    XCTAssertEqual(player.rate, 0)
    player.onPlaybackStart = {
      player.onPlaybackStart = nil
      wrapper.seek(to: 12)
    }

    player.completions[0](true)
    drainMainQueue()
    player.completions[1](true)
    drainMainQueue()

    XCTAssertEqual(results, [false])
    XCTAssertEqual(delegate.seeks, [8, 12])
    XCTAssertEqual(delegate.seekOutcomes, [false, true])
    wrapper.unload()
  }

  func testSeekCancellationSelectingTrackSupersedesOuterLoadAndItsInitialTime() {
    let replacementURL = URL(fileURLWithPath: "/yrt-tests/replacement.mp3")
    let interruptedURL = URL(fileURLWithPath: "/yrt-tests/interrupted.mp3")
    let oldAsset = WrapperLoadingAsset(url: trackURL)
    let replacementAsset = WrapperLoadingAsset(url: replacementURL)
    var loadedURLs: [URL] = []
    let wrapper = AVPlayerWrapper(makeAsset: { url, _ in
      loadedURLs.append(url)
      return url == replacementURL ? replacementAsset : oldAsset
    })
    let player = WrapperSeekingPlayer()
    wrapper.avPlayer = player
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.seek(
      to: 8,
      completionHandler: { finished in
        XCTAssertFalse(finished)
        wrapper.load(from: replacementURL, playWhenReady: false, initialTime: 7)
      })

    wrapper.load(from: interruptedURL, playWhenReady: true, initialTime: 25)
    replacementAsset.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(loadedURLs, [trackURL, replacementURL])
    XCTAssertEqual(wrapper.url, replacementURL)
    XCTAssertTrue(wrapper.currentItem?.asset === replacementAsset)
    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(player.targets, [7])
    wrapper.unload()
  }

  func testLoadingFailureCancelsDeferredSeekCompletion() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    var results: [Bool] = []
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.seek(to: 8, completionHandler: { results.append($0) })

    wrapper.itemFailedToPlayToEndTime()
    wrapper.unload()

    XCTAssertEqual(results, [false])
  }

  func testLatePlaybackReadinessCannotReviveFailedTrackOrDuplicateFailure() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.itemFailedToPlayToEndTime()

    wrapper.item(didUpdatePlaybackLikelyToKeepUp: true)
    wrapper.player(didChangeTimeControlStatus: .waitingToPlayAtSpecifiedRate)
    wrapper.player(didChangeTimeControlStatus: .playing)
    wrapper.itemFailedToPlayToEndTime()

    XCTAssertEqual(wrapper.state, .failed)
    XCTAssertEqual(delegate.failures, 1)
    wrapper.unload()
  }

  func testLoadingDelegatePauseSupersedesInitialPlayIntent() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate
    delegate.onState = { state in
      if state == .loading { wrapper.pause() }
    }

    wrapper.load(from: trackURL, playWhenReady: true)

    XCTAssertFalse(wrapper.playWhenReady)
    wrapper.unload()
  }

  func testLoadingDelegateSeekSupersedesInitialTime() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    delegate.onState = { state in
      if state == .loading { wrapper.seek(to: 7) }
    }
    wrapper.delegate = delegate

    wrapper.load(from: trackURL, playWhenReady: false, initialTime: 25)
    asset.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.targets, [7])
    wrapper.unload()
  }

  func testPendingSeekPositionTracksLatestRequestAndClearsOnlyForItsOwnedCompletion() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    XCTAssertNil(wrapper.pendingSeekPosition)
    XCTAssertNil(wrapper.recoveryPosition)
    wrapper.seek(to: 25)
    XCTAssertEqual(wrapper.pendingSeekPosition, 25)
    XCTAssertEqual(wrapper.recoveryPosition, 25)
    wrapper.seek(by: -30)
    XCTAssertEqual(wrapper.pendingSeekPosition, 0)
    XCTAssertEqual(wrapper.recoveryPosition, 0)

    wrapper.load(from: trackURL, playWhenReady: false, initialTime: 40)
    XCTAssertEqual(wrapper.pendingSeekPosition, 40)
    XCTAssertEqual(wrapper.recoveryPosition, 40)
    asset.finishPlayable()
    drainMainQueue()
    wrapper.seek(to: 7)
    XCTAssertEqual(wrapper.pendingSeekPosition, 7)
    XCTAssertEqual(wrapper.recoveryPosition, 7)

    player.completions[0](true)
    drainMainQueue()
    XCTAssertEqual(wrapper.pendingSeekPosition, 7)
    XCTAssertEqual(wrapper.recoveryPosition, 7)

    player.completions[1](true)
    drainMainQueue()
    XCTAssertNil(wrapper.pendingSeekPosition)
    XCTAssertNil(wrapper.recoveryPosition)
    wrapper.seek(to: 12)
    wrapper.unload()
    XCTAssertNil(wrapper.pendingSeekPosition)
    XCTAssertNil(wrapper.recoveryPosition)
  }

  func testAutoplayWaitsForInitialSeekBeforeStartingNativePlayback() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })

    wrapper.load(from: trackURL, playWhenReady: true, initialTime: 25)
    asset.finishPlayable()
    drainMainQueue()

    XCTAssertTrue(wrapper.playWhenReady)
    XCTAssertEqual(player.targets, [25])
    XCTAssertEqual(player.ratesAtInstallation, [0])
    XCTAssertEqual(player.ratesAtSeekStart, [0])
    XCTAssertTrue(player.startedItems.isEmpty)
    XCTAssertEqual(player.rate, 0)

    player.completions[0](true)
    drainMainQueue()

    XCTAssertEqual(player.rate, 1)
    XCTAssertEqual(player.startedItems.count, 1)
    wrapper.unload()
  }

  func testQueuedSeekCompletionRespectsHostPlaybackPermission() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    var playbackAllowed = true
    wrapper.playbackPermission = { playbackAllowed }

    wrapper.load(from: trackURL, playWhenReady: true, initialTime: 25)
    asset.finishPlayable()
    drainMainQueue()
    XCTAssertEqual(player.targets, [25])

    player.completions[0](true)
    playbackAllowed = false
    drainMainQueue()

    XCTAssertEqual(player.rate, 0)
    XCTAssertTrue(player.startedItems.isEmpty)

    wrapper.pause()
    playbackAllowed = true
    wrapper.play()
    XCTAssertEqual(player.rate, 1)
    XCTAssertEqual(player.startedItems.count, 1)
    wrapper.unload()
  }

  func testLoadingDelegateSeekRetainsInitialPlaybackGateAndLatestRate() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    delegate.onState = { state in
      if state == .loading { wrapper.seek(to: 7) }
    }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: true, initialTime: 25)
    asset.finishPlayable()
    drainMainQueue()
    wrapper.rate = 1.75

    XCTAssertEqual(player.targets, [7])
    XCTAssertEqual(player.rate, 0)
    XCTAssertTrue(player.startedItems.isEmpty)

    player.completions[0](true)
    drainMainQueue()

    XCTAssertEqual(player.rate, 1.75)
    XCTAssertEqual(player.startedItems.count, 1)
    wrapper.unload()
  }

  func testReplacementPauseDelegateSeekWaitsForReplacementItemBeforeResumingAutoplay() {
    for completesBeforeInstallation in [false, true] {
      let firstAsset = WrapperLoadingAsset(url: trackURL)
      let nextAsset = WrapperLoadingAsset(url: trackURL)
      var assets = [firstAsset, nextAsset]
      let player = WrapperSynchronousPauseSeekingPlayer()
      let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
      wrapper.load(from: trackURL, playWhenReady: true)
      firstAsset.finishPlayable()
      drainMainQueue()
      player.reportTimeControlStatus(.playing)
      let delegate = WrapperCorrectnessDelegate()
      var outcomes: [Bool] = []
      delegate.onState = { state in
        if state == .idle {
          wrapper.seek(to: 7, completionHandler: { outcomes.append($0) })
        }
      }
      wrapper.delegate = delegate

      wrapper.load(from: trackURL, playWhenReady: true, initialTime: 25)
      delegate.onState = nil

      XCTAssertEqual(delegate.states, [.idle, .loading])
      XCTAssertTrue(player.targets.isEmpty)
      XCTAssertEqual(wrapper.pendingSeekPosition, 7)
      if completesBeforeInstallation {
        player.completions.first?(true)
        drainMainQueue()
        XCTAssertEqual(wrapper.pendingSeekPosition, 7)
        XCTAssertTrue(outcomes.isEmpty)
      }
      nextAsset.finishPlayable()
      drainMainQueue()

      XCTAssertEqual(player.targets, [7])
      XCTAssertEqual(player.soughtItems.count, 1)
      XCTAssertTrue(player.soughtItems.first === wrapper.currentItem)
      XCTAssertEqual(player.rate, 0)
      XCTAssertEqual(wrapper.pendingSeekPosition, 7)
      player.completions.first?(true)
      drainMainQueue()

      XCTAssertEqual(outcomes, [true])
      XCTAssertNil(wrapper.pendingSeekPosition)
      XCTAssertTrue(wrapper.playWhenReady)
      XCTAssertEqual(player.rate, 1)
      wrapper.unload()
    }
  }

  func testInstalledDelegateSeekRetainsGateUntilReplacementSeekCompletes() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    delegate.onInstallItem = { _ in wrapper.seek(to: 7) }
    wrapper.delegate = delegate

    wrapper.load(from: trackURL, playWhenReady: true, initialTime: 25)
    asset.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.targets, [7])
    XCTAssertTrue(player.startedItems.isEmpty)
    XCTAssertEqual(player.rate, 0)

    player.completions[0](true)
    drainMainQueue()

    XCTAssertEqual(player.rate, 1)
    wrapper.unload()
  }

  func testPauseDuringInitialSeekPreventsCompletionFromStartingPlayback() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true, initialTime: 25)
    asset.finishPlayable()
    drainMainQueue()
    wrapper.pause()
    player.completions[0](true)
    drainMainQueue()

    XCTAssertFalse(wrapper.playWhenReady)
    XCTAssertEqual(player.rate, 0)
    XCTAssertTrue(player.startedItems.isEmpty)
    wrapper.unload()
  }

  func testRetiredInitialSeekCannotReleaseReplacementPlaybackGate() {
    let first = WrapperLoadingAsset(url: trackURL)
    let replacement = WrapperLoadingAsset(url: trackURL)
    var assets = [first, replacement]
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: true, initialTime: 25)
    first.finishPlayable()
    drainMainQueue()
    wrapper.load(from: trackURL, playWhenReady: true, initialTime: 40)
    replacement.finishPlayable()
    drainMainQueue()

    player.completions[0](true)
    drainMainQueue()

    XCTAssertEqual(player.targets, [25, 40])
    XCTAssertEqual(player.rate, 0)
    XCTAssertTrue(player.startedItems.isEmpty)

    player.completions[1](true)
    drainMainQueue()

    XCTAssertEqual(player.rate, 1)
    XCTAssertEqual(player.startedItems.count, 1)
    wrapper.unload()
  }

  func testReloadPreservesInitialAndUserSeekTargetsBeforeItemInstallation() {
    for usesUserSeek in [false, true] {
      let first = WrapperLoadingAsset(url: trackURL)
      let replacement = WrapperLoadingAsset(url: trackURL)
      var assets = [first, replacement]
      let player = WrapperControlledSeekingPlayer()
      let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
      var outcomes: [Bool] = []
      wrapper.load(from: trackURL, playWhenReady: true, initialTime: usesUserSeek ? nil : 25)
      if usesUserSeek { wrapper.seek(to: 25, completionHandler: { outcomes.append($0) }) }

      wrapper.reload(startFromCurrentTime: true)
      XCTAssertEqual(wrapper.pendingSeekPosition, 25)
      replacement.finishPlayable()
      drainMainQueue()

      XCTAssertEqual(player.targets, [25])
      XCTAssertEqual(player.rate, 0)
      XCTAssertEqual(outcomes, usesUserSeek ? [false] : [])
      player.completions.first?(true)
      drainMainQueue()
      XCTAssertNil(wrapper.pendingSeekPosition)
      XCTAssertEqual(player.rate, 1)
      wrapper.unload()
    }
  }

  func testReloadPreservesInFlightSeekTargetAndIgnoresRetiredCompletion() {
    let first = WrapperLoadingAsset(url: trackURL)
    let replacement = WrapperLoadingAsset(url: trackURL)
    var assets = [first, replacement]
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: true)
    first.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)
    wrapper.seek(to: 25)

    wrapper.reload(startFromCurrentTime: true)
    replacement.finishPlayable()
    drainMainQueue()
    XCTAssertEqual(player.targets, [25, 25])

    player.completions[0](true)
    drainMainQueue()
    XCTAssertEqual(wrapper.pendingSeekPosition, 25)
    XCTAssertEqual(player.rate, 0)
    player.completions[1](true)
    drainMainQueue()
    XCTAssertNil(wrapper.pendingSeekPosition)
    XCTAssertEqual(player.rate, 1)
    wrapper.unload()
  }

  func testRetryPreservesRequestedResumePositionAfterKeyOrItemFailure() {
    for failsPlayableKey in [false, true] {
      let first = WrapperLoadingAsset(url: trackURL)
      let replacement = WrapperLoadingAsset(url: trackURL)
      var assets = [first, replacement]
      let player = WrapperControlledSeekingPlayer()
      let item = WrapperStatusItem(asset: first)
      let wrapper = AVPlayerWrapper(
        player: player, makeAsset: { _, _ in assets.removeFirst() },
        makePlayerItem: { asset, _ in
          asset === first ? item : WrapperStatusItem(asset: asset)
        })
      wrapper.load(from: trackURL, playWhenReady: false, initialTime: 25)
      if failsPlayableKey {
        first.failPlayable()
      } else {
        first.finishPlayable()
        drainMainQueue()
        item.fail()
      }
      drainMainQueue()
      XCTAssertEqual(wrapper.state, .failed)
      XCTAssertNil(wrapper.pendingSeekPosition)
      XCTAssertEqual(wrapper.recoveryPosition, 25)

      wrapper.reload(startFromCurrentTime: true)
      XCTAssertEqual(wrapper.pendingSeekPosition, 25)
      XCTAssertEqual(wrapper.recoveryPosition, 25)
      wrapper.avPlayer = player
      replacement.finishPlayable()
      drainMainQueue()

      XCTAssertEqual(player.targets.last, 25)
      player.completions.last?(true)
      drainMainQueue()
      XCTAssertNil(wrapper.pendingSeekPosition)
      XCTAssertNil(wrapper.recoveryPosition)
      wrapper.unload()
    }
  }

  func testRetryUsesSeekRequestedAfterInstalledItemFailure() {
    let first = WrapperLoadingAsset(url: trackURL)
    let replacement = WrapperLoadingAsset(url: trackURL)
    var assets = [first, replacement]
    let player = WrapperControlledSeekingPlayer()
    let item = WrapperStatusItem(asset: first)
    let wrapper = AVPlayerWrapper(
      player: player, makeAsset: { _, _ in assets.removeFirst() },
      makePlayerItem: { asset, _ in
        asset === first ? item : WrapperStatusItem(asset: asset)
      })
    defer { wrapper.unload() }

    wrapper.load(from: trackURL, playWhenReady: false)
    first.finishPlayable()
    drainMainQueue()
    wrapper.seek(to: 25)
    item.fail()
    XCTAssertEqual(wrapper.state, .failed)
    XCTAssertTrue(wrapper.currentItem === item)
    XCTAssertEqual(wrapper.recoveryPosition, 25)

    wrapper.seek(to: 40)
    XCTAssertEqual(player.targets, [25])
    for completion in player.completions { completion(false) }
    drainMainQueue()
    XCTAssertEqual(wrapper.pendingSeekPosition, 40)
    XCTAssertEqual(wrapper.recoveryPosition, 40)

    wrapper.reload(startFromCurrentTime: true)
    wrapper.avPlayer = player
    replacement.finishPlayable()
    drainMainQueue()
    XCTAssertEqual(player.targets, [25, 40])
    XCTAssertEqual(wrapper.pendingSeekPosition, 40)
    player.completions.last?(true)
    drainMainQueue()
    XCTAssertNil(wrapper.recoveryPosition)
  }

  func testNewSourceAndExplicitZeroResumeSupersedeFailedSeekPosition() {
    for startsAtExplicitZero in [false, true] {
      let first = WrapperLoadingAsset(url: trackURL)
      let replacementURL = URL(fileURLWithPath: "/yrt-tests/replacement.mp3")
      let replacement = WrapperLoadingAsset(url: replacementURL)
      var assets = [first, replacement]
      let player = WrapperControlledSeekingPlayer()
      let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
      wrapper.load(from: trackURL, playWhenReady: false, initialTime: 25)
      first.failPlayable()
      drainMainQueue()
      XCTAssertNil(wrapper.pendingSeekPosition)
      XCTAssertEqual(wrapper.recoveryPosition, 25)

      wrapper.load(
        from: replacementURL, playWhenReady: false,
        initialTime: startsAtExplicitZero ? 0 : nil)
      wrapper.avPlayer = player
      replacement.finishPlayable()
      drainMainQueue()

      XCTAssertEqual(player.targets, startsAtExplicitZero ? [0] : [])
      XCTAssertEqual(wrapper.pendingSeekPosition, startsAtExplicitZero ? 0 : nil)
      XCTAssertEqual(wrapper.recoveryPosition, startsAtExplicitZero ? 0 : nil)
      wrapper.unload()
      XCTAssertNil(wrapper.recoveryPosition)
    }
  }

  func testReloadFromStartAndStopThenPlayDiscardFailedSeekPosition() {
    for stopsBeforePlaying in [false, true] {
      let first = WrapperLoadingAsset(url: trackURL)
      let replacement = WrapperLoadingAsset(url: trackURL)
      var assets = [first, replacement]
      let player = WrapperControlledSeekingPlayer()
      let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
      wrapper.load(from: trackURL, playWhenReady: false, initialTime: 25)
      first.failPlayable()
      drainMainQueue()
      XCTAssertEqual(wrapper.recoveryPosition, 25)

      if stopsBeforePlaying {
        wrapper.stop()
        XCTAssertNil(wrapper.recoveryPosition)
        wrapper.play()
      } else {
        wrapper.reload(startFromCurrentTime: false)
      }
      wrapper.avPlayer = player
      replacement.finishPlayable()
      drainMainQueue()

      XCTAssertNil(wrapper.pendingSeekPosition)
      XCTAssertNil(wrapper.recoveryPosition)
      XCTAssertTrue(player.targets.isEmpty)
      wrapper.unload()
    }
  }

  func testExplicitSeekSupersedesFailedRecoveryTargetAndStopRetiresIt() {
    for replacementTarget in [0.0, 7.0] {
      let asset = WrapperLoadingAsset(url: trackURL)
      let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
      wrapper.load(from: trackURL, playWhenReady: false, initialTime: 25)
      asset.failPlayable()
      drainMainQueue()
      XCTAssertNil(wrapper.pendingSeekPosition)
      XCTAssertEqual(wrapper.recoveryPosition, 25)

      wrapper.seek(to: replacementTarget)

      XCTAssertEqual(wrapper.pendingSeekPosition, replacementTarget)
      XCTAssertEqual(wrapper.recoveryPosition, replacementTarget)
      wrapper.stop()
      XCTAssertNil(wrapper.pendingSeekPosition)
      XCTAssertNil(wrapper.recoveryPosition)
      wrapper.unload()
    }
  }

  func testPlayAfterStopWaitsForSeekRequestedAfterStop() throws {
    let first = WrapperLoadingAsset(url: trackURL)
    let replacement = WrapperLoadingAsset(url: trackURL)
    var assets = [first, replacement]
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    defer { wrapper.unload() }
    wrapper.load(from: trackURL, playWhenReady: false)
    first.finishPlayable()
    drainMainQueue()

    var retiredSeekOutcomes: [Bool] = []
    wrapper.seek(to: 7, completionHandler: { retiredSeekOutcomes.append($0) })
    let completeRetiredSeek = try XCTUnwrap(player.completions.first)
    wrapper.stop()
    XCTAssertEqual(retiredSeekOutcomes, [false])
    var restartSeekOutcomes: [Bool] = []
    wrapper.seek(to: 25, completionHandler: { restartSeekOutcomes.append($0) })
    wrapper.play()
    replacement.finishPlayable()
    drainMainQueue()

    completeRetiredSeek(true)
    drainMainQueue()
    XCTAssertEqual(retiredSeekOutcomes, [false])
    XCTAssertTrue(restartSeekOutcomes.isEmpty)
    XCTAssertEqual(player.targets, [7, 25])
    XCTAssertEqual(player.rate, 0)

    let completeRestartSeek = try XCTUnwrap(player.completions.dropFirst().first)
    completeRestartSeek(true)
    drainMainQueue()
    XCTAssertEqual(restartSeekOutcomes, [true])
    XCTAssertEqual(player.rate, 1)
  }

  func testNewSourceAtSamePositionCancelsSeekRequestedAfterStop() {
    let replacementURL = URL(fileURLWithPath: "/yrt-tests/replacement.mp3")
    let first = WrapperLoadingAsset(url: trackURL)
    let replacement = WrapperLoadingAsset(url: replacementURL)
    var assets = [first, replacement]
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    defer { wrapper.unload() }
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.stop()

    var outcomes: [Bool] = []
    wrapper.seek(to: 25, completionHandler: { outcomes.append($0) })
    wrapper.load(from: replacementURL, playWhenReady: true, initialTime: 25)
    replacement.finishPlayable()
    drainMainQueue()
    player.completions.first?(true)
    drainMainQueue()

    XCTAssertEqual(outcomes, [false])
    XCTAssertEqual(player.targets, [25])
    XCTAssertEqual(player.rate, 1)
  }

  func testUnsuccessfulNormalSeekDoesNotBecomeRetryResumePosition() {
    let first = WrapperLoadingAsset(url: trackURL)
    let replacement = WrapperLoadingAsset(url: trackURL)
    var assets = [first, replacement]
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: false)
    first.finishPlayable()
    drainMainQueue()
    wrapper.seek(to: 25)
    player.completions[0](false)
    drainMainQueue()
    XCTAssertNil(wrapper.pendingSeekPosition)
    XCTAssertNil(wrapper.recoveryPosition)

    wrapper.reload(startFromCurrentTime: true)
    replacement.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.targets, [25, 0])
    wrapper.unload()
  }

  func testFailedBlockingSeekKeepsPlaybackHeldAndRetriesAtRequestedPosition() throws {
    for seeksDuringLoad in [false, true] {
      let first = WrapperLoadingAsset(url: trackURL)
      let replacement = WrapperLoadingAsset(url: trackURL)
      var assets = [first, replacement]
      let player = WrapperControlledSeekingPlayer()
      let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
      let delegate = WrapperCorrectnessDelegate()
      wrapper.delegate = delegate
      defer { wrapper.unload() }

      var results: [Bool] = []
      wrapper.load(from: trackURL, playWhenReady: true, initialTime: seeksDuringLoad ? nil : 25)
      if seeksDuringLoad { wrapper.seek(to: 25, completionHandler: { results.append($0) }) }
      first.finishPlayable()
      drainMainQueue()

      let firstCompletion = try XCTUnwrap(player.completions.first)
      firstCompletion(false)
      drainMainQueue()
      XCTAssertEqual(wrapper.state, .failed)
      XCTAssertNil(wrapper.pendingSeekPosition)
      XCTAssertEqual(wrapper.recoveryPosition, 25)
      XCTAssertEqual(player.rate, 0)
      XCTAssertTrue(player.startedItems.isEmpty)
      XCTAssertEqual(delegate.failures, 1)
      XCTAssertEqual(delegate.seeks, [25])
      XCTAssertEqual(delegate.seekOutcomes, [false])
      XCTAssertEqual(results, seeksDuringLoad ? [false] : [])

      wrapper.reload(startFromCurrentTime: true)
      wrapper.avPlayer = player
      replacement.finishPlayable()
      drainMainQueue()
      XCTAssertEqual(player.targets, [25, 25])
      XCTAssertEqual(player.rate, 0)

      let retryCompletion = try XCTUnwrap(player.completions.last)
      retryCompletion(true)
      drainMainQueue()
      XCTAssertNil(wrapper.recoveryPosition)
      XCTAssertEqual(player.rate, 1)
      XCTAssertEqual(delegate.failures, 1)
      XCTAssertEqual(delegate.seekOutcomes, [false, true])
      XCTAssertEqual(results, seeksDuringLoad ? [false] : [])
    }
  }

  func testReloadWaitsForResumeSeekBeforeStartingNativePlayback() {
    let first = WrapperLoadingAsset(url: trackURL)
    let replacement = WrapperLoadingAsset(url: trackURL)
    var assets = [first, replacement]
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: true)
    first.finishPlayable()
    drainMainQueue()
    let startsBeforeReload = player.startedItems.count

    wrapper.reload(startFromCurrentTime: true)
    replacement.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.ratesAtInstallation.last, 0)
    XCTAssertEqual(player.ratesAtSeekStart, [0])
    XCTAssertEqual(player.startedItems.count, startsBeforeReload)

    player.completions[0](true)
    drainMainQueue()

    XCTAssertEqual(player.rate, 1)
    XCTAssertEqual(player.startedItems.count, startsBeforeReload + 1)
    wrapper.unload()
  }

  func testRegularPlayingSeekKeepsNativePlaybackRunning() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperControlledSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)

    wrapper.seek(to: 25)

    XCTAssertEqual(player.rate, 1)
    XCTAssertEqual(player.ratesAtSeekStart, [1])
    player.completions[0](true)
    drainMainQueue()
    XCTAssertEqual(player.rate, 1)
    wrapper.unload()
  }

  func testInitialTimeIsAppliedWhenLoadingDelegateDoesNotSeek() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })

    wrapper.load(from: trackURL, playWhenReady: false, initialTime: 25)
    asset.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.targets, [25])
    wrapper.unload()
  }

  func testLoadingDelegateSeekSupersedesReloadResumeTime() throws {
    let firstAsset = WrapperLoadingAsset(url: trackURL)
    let nextAsset = WrapperLoadingAsset(url: trackURL)
    var assets = [firstAsset, nextAsset]
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: false)
    firstAsset.finishPlayable()
    drainMainQueue()
    XCTAssertEqual(try XCTUnwrap(wrapper.currentItem).currentTime().seconds, 0)
    wrapper.item(didUpdatePlaybackLikelyToKeepUp: true)
    let delegate = WrapperCorrectnessDelegate()
    delegate.onState = { state in
      if state == .loading { wrapper.seek(to: 7) }
    }
    wrapper.delegate = delegate

    wrapper.reload(startFromCurrentTime: true)
    nextAsset.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.targets, [7])
    wrapper.unload()
  }

  func testReloadResumeTimeIsAppliedWhenLoadingDelegateDoesNotSeek() throws {
    let firstAsset = WrapperLoadingAsset(url: trackURL)
    let nextAsset = WrapperLoadingAsset(url: trackURL)
    var assets = [firstAsset, nextAsset]
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: false)
    firstAsset.finishPlayable()
    drainMainQueue()
    XCTAssertEqual(try XCTUnwrap(wrapper.currentItem).currentTime().seconds, 0)

    wrapper.reload(startFromCurrentTime: true)
    nextAsset.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.targets, [0])
    wrapper.unload()
  }

  func testSeekCancellationDelegateSeekSupersedesInitialTime() {
    let firstAsset = WrapperLoadingAsset(url: trackURL)
    let nextAsset = WrapperLoadingAsset(url: trackURL)
    var assets = [firstAsset, nextAsset]
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.seek(
      to: 8,
      completionHandler: { finished in
        XCTAssertFalse(finished)
        wrapper.seek(to: 7)
      })

    wrapper.load(from: trackURL, playWhenReady: false, initialTime: 25)
    nextAsset.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.targets, [7])
    wrapper.unload()
  }

  func testInstalledItemDelegateConfiguresCurrentAutoplayItem() throws {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperTransportPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    var installedItems: [AVPlayerItem] = []
    delegate.onInstallItem = { item in
      XCTAssertTrue(wrapper.currentItem === item)
      installedItems.append(item)
      item.audioTimePitchAlgorithm = .spectral
    }
    wrapper.delegate = delegate

    wrapper.load(from: trackURL, playWhenReady: true)
    asset.finishPlayable()
    drainMainQueue()
    player.reportTimeControlStatus(.playing)

    XCTAssertEqual(installedItems.count, 1)
    XCTAssertEqual(try XCTUnwrap(wrapper.currentItem).audioTimePitchAlgorithm, .spectral)
    XCTAssertEqual(wrapper.state, .playing)
    wrapper.unload()
  }

  func testInstalledItemDelegateSeekSupersedesInitialTimeAndStartsOnce() {
    let asset = WrapperLoadingAsset(url: trackURL)
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in asset })
    let delegate = WrapperCorrectnessDelegate()
    delegate.onInstallItem = { _ in wrapper.seek(to: 7) }
    wrapper.delegate = delegate

    wrapper.load(from: trackURL, playWhenReady: false, initialTime: 25)
    asset.finishPlayable()
    drainMainQueue()

    XCTAssertEqual(player.targets, [7])
    wrapper.unload()
  }

  func testInstalledItemDelegateSelectingReplacementKeepsReplacementCurrent() throws {
    let firstAsset = WrapperLoadingAsset(url: trackURL)
    let nextAsset = WrapperLoadingAsset(url: trackURL)
    var assets = [firstAsset, nextAsset]
    let player = WrapperSeekingPlayer()
    let wrapper = AVPlayerWrapper(player: player, makeAsset: { _, _ in assets.removeFirst() })
    let delegate = WrapperCorrectnessDelegate()
    delegate.onInstallItem = { item in
      if item.asset === firstAsset {
        wrapper.load(from: self.trackURL, playWhenReady: false, initialTime: 7)
      }
    }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: true, initialTime: 25)
    firstAsset.finishPlayable()
    drainMainQueue()

    nextAsset.finishPlayable()
    drainMainQueue()

    XCTAssertTrue(try XCTUnwrap(wrapper.currentItem).asset === nextAsset)
    XCTAssertEqual(player.targets, [7])
    XCTAssertFalse(wrapper.playWhenReady)
    wrapper.unload()
  }

  func testObserverTeardownPreservesMetadataOutputsOwnedByCaller() {
    let item = AVPlayerItem(url: trackURL)
    let output = AVPlayerItemMetadataOutput()
    item.add(output)
    let observer = AVPlayerItemObserver()
    observer.startObserving(item: item)

    observer.stopObservingCurrentItem()

    XCTAssertTrue(item.outputs.contains { $0 === output })
    XCTAssertEqual(item.outputs.count, 1)
  }

  func testPlayerFailureWithoutInstalledItemReportsFailureWithoutCrashing() {
    let wrapper = AVPlayerWrapper()
    let delegate = WrapperCorrectnessDelegate()
    wrapper.delegate = delegate

    wrapper.player(statusDidChange: .failed)

    XCTAssertEqual(wrapper.state, .failed)
    XCTAssertEqual(delegate.failures, 1)
  }
}
