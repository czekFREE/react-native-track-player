#if os(iOS)
  import AVFoundation
  import MediaPlayer
  import UIKit
  import XCTest

  private final class PlayerNowPlayingController: NowPlayingInfoControllerProtocol {
    var values: [String: Any] = [:]
    var artworkThreads: [Bool] = []

    required init() {}
    required init(infoCenter: NowPlayingInfoCenter) {}

    func set(keyValue: NowPlayingInfoKeyValue) {
      if keyValue.getKey() == MPMediaItemPropertyArtwork {
        artworkThreads.append(Thread.isMainThread)
      }
      values[keyValue.getKey()] = keyValue.getValue()
    }

    func set(keyValues: [NowPlayingInfoKeyValue]) {
      for keyValue in keyValues { set(keyValue: keyValue) }
    }

    func setWithoutUpdate(keyValues: [NowPlayingInfoKeyValue]) {
      set(keyValues: keyValues)
    }

    func clear() {
      values = [:]
    }
  }

  private final class PlayerArtworkItem: DefaultAudioItem {
    var artworkRequests: [(UIImage?) -> Void] = []

    init(title: String) {
      super.init(audioUrl: "/yrt-tests/\(title).wav", title: title, sourceType: .file)
    }

    override func getArtwork(_ handler: @escaping (UIImage?) -> Void) {
      artworkRequests.append(handler)
    }
  }

  private final class PlayerPendingAsset: AVURLAsset, @unchecked Sendable {
    override func loadValuesAsynchronously(
      forKeys keys: [String], completionHandler handler: (() -> Void)? = nil
    ) {}
  }

  private final class PlayerDurationAsset: AVURLAsset, @unchecked Sendable {
    var reportedDuration = CMTime.indefinite

    override func statusOfValue(forKey key: String, error outError: NSErrorPointer)
      -> AVKeyValueStatus
    {
      key == "duration" ? .loaded : .unknown
    }

    override var duration: CMTime { reportedDuration }
  }

  private final class PlayerSeekBoundary: AVPlayer {
    private var loadedItem: AVPlayerItem?
    private var playbackRate: Float = 0
    var seekCompletions: [(Bool) -> Void] = []
    var requestedTimes: [Double] = []
    var onSeek: (() -> Void)?

    init(item: AVPlayerItem) {
      loadedItem = item
      super.init()
    }

    override var currentItem: AVPlayerItem? { loadedItem }
    override func replaceCurrentItem(with item: AVPlayerItem?) {
      loadedItem = item
      super.replaceCurrentItem(with: item)
    }

    override var rate: Float {
      get { playbackRate }
      set { playbackRate = newValue }
    }

    override func seek(
      to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
      completionHandler: @escaping (Bool) -> Void
    ) {
      onSeek?()
      requestedTimes.append(time.seconds)
      seekCompletions.append(completionHandler)
    }
  }

  private final class PlayerPitchObserver: AudioPlayer {
    var installed: ((AVAudioTimePitchAlgorithm) -> Void)?

    override func AVWrapper(didInstallItem item: AVPlayerItem) {
      super.AVWrapper(didInstallItem: item)
      installed?(item.audioTimePitchAlgorithm)
    }
  }

  final class SwiftAudioExPlayerTests: XCTestCase {
    private func runOnBackgroundAndWaitForCompletion(_ action: @escaping () -> Void) {
      let completed = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        XCTAssertFalse(Thread.isMainThread)
        action()
        completed.signal()
      }
      XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
    }

    private func drainMainQueue() {
      let drained = expectation(description: "Main queue drained")
      DispatchQueue.main.async { drained.fulfill() }
      wait(for: [drained], timeout: 2)
    }

    private func makeImage(width: CGFloat) -> UIImage {
      UIGraphicsImageRenderer(size: CGSize(width: width, height: 1)).image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
      }
    }

    private func installSeekBoundary(on player: AudioPlayer) throws -> PlayerSeekBoundary {
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      let asset = PlayerPendingAsset(url: URL(fileURLWithPath: "/yrt-tests/pending.wav"))
      let item = AVPlayerItem(asset: asset)
      let boundary = PlayerSeekBoundary(item: item)
      wrapper.asset = asset
      wrapper.item = item
      wrapper.avPlayer = boundary
      wrapper.state = .ready
      return boundary
    }

    private func makeRepeatingPlayer(mode: RepeatMode = .track) throws
      -> (QueuedAudioPlayer, PlayerSeekBoundary)
    {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      player.add(item: PlayerArtworkItem(title: "repeat"), playWhenReady: true)
      player.repeatMode = mode
      return (player, try installSeekBoundary(on: player))
    }

    func testOriginalSeekAndMetadataRefreshMethodsRemainUsableAsFunctionValues() throws {
      let player = AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      let item = PlayerArtworkItem(title: "method-reference")
      player.load(item: item, playWhenReady: false)
      let boundary = try installSeekBoundary(on: player)
      let seek: (TimeInterval) -> Void = player.seek(to:)
      let refresh: () -> Void = player.loadNowPlayingMetaValues

      refresh()
      seek(12)

      XCTAssertEqual(item.artworkRequests.count, 2)
      XCTAssertEqual(boundary.requestedTimes, [12])
      XCTAssertEqual(player.pendingSeekPosition, 12)
      XCTAssertEqual(player.recoveryPosition, 12)
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()
      XCTAssertNil(player.pendingSeekPosition)
      XCTAssertNil(player.recoveryPosition)
      player.clear()
    }

    private func expectReentrantLoadIntent(
      player: AudioPlayer, replacementIntent: Bool?, expectedIntent: Bool
    ) throws {
      player.load(item: PlayerArtworkItem(title: "initial"), playWhenReady: false)
      _ = try installSeekBoundary(on: player)
      let replacement = PlayerArtworkItem(title: "newest")
      var cancellationCount = 0
      player.seek(to: 10) { finished in
        XCTAssertFalse(finished)
        cancellationCount += 1
        player.load(item: replacement, playWhenReady: replacementIntent)
      }

      player.load(item: PlayerArtworkItem(title: "superseded"), playWhenReady: true)

      XCTAssertEqual(cancellationCount, 1)
      XCTAssertEqual(player.currentItem?.getTitle(), "newest")
      XCTAssertEqual(player.playWhenReady, expectedIntent)
    }

    func testAudioPlayerLoadKeepsNewerPausedIntentFromSeekCancellation() throws {
      try expectReentrantLoadIntent(
        player: AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        replacementIntent: false, expectedIntent: false)
    }

    func testQueuedPlayerLoadKeepsNewerPausedIntentFromSeekCancellation() throws {
      try expectReentrantLoadIntent(
        player: QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        replacementIntent: false, expectedIntent: false)
    }

    func testAudioPlayerReentrantLoadWithoutIntentKeepsLatestExplicitIntent() throws {
      try expectReentrantLoadIntent(
        player: AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        replacementIntent: nil, expectedIntent: true)
    }

    func testQueuedPlayerReentrantLoadWithoutIntentKeepsLatestExplicitIntent() throws {
      try expectReentrantLoadIntent(
        player: QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        replacementIntent: nil, expectedIntent: true)
    }

    func testQueuedPlayerInitialLoadHonorsRequestedPlaybackIntent() {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())

      player.load(item: PlayerArtworkItem(title: "autoplay"), playWhenReady: true)

      XCTAssertTrue(player.playWhenReady)
      XCTAssertEqual(player.currentItem?.getTitle(), "autoplay")
    }

    private func expectPausedLoadPreservesCallbackSource(
      player: AudioPlayer, clearsSource: Bool
    ) throws {
      player.load(item: PlayerArtworkItem(title: "initial"), playWhenReady: true)
      var handledPause = false
      player.event.playWhenReadyChange.addListener(self, onMainQueue: true) { ready in
        guard !ready, !handledPause else { return }
        handledPause = true
        if clearsSource {
          player.clear()
        } else {
          player.load(item: PlayerArtworkItem(title: "newest"), playWhenReady: true)
        }
      }

      player.load(item: PlayerArtworkItem(title: "superseded"), playWhenReady: false)

      XCTAssertTrue(handledPause)
      XCTAssertEqual(player.currentItem?.getTitle(), clearsSource ? nil : "newest")
      XCTAssertEqual(player.playWhenReady, !clearsSource)
      let controller = try XCTUnwrap(player.nowPlayingInfoController as? PlayerNowPlayingController)
      XCTAssertEqual(
        controller.values[MPMediaItemPropertyTitle] as? String, clearsSource ? nil : "newest")
      if let queuedPlayer = player as? QueuedAudioPlayer {
        XCTAssertEqual(
          queuedPlayer.items.compactMap { $0.getTitle() }, clearsSource ? [] : ["newest"])
        XCTAssertEqual(queuedPlayer.currentIndex, clearsSource ? -1 : 0)
      }
    }

    func testAudioPlayerPausedLoadPreservesNewSourceSelectedByPlaybackIntentListener() throws {
      try expectPausedLoadPreservesCallbackSource(
        player: AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        clearsSource: false)
    }

    func testQueuedPlayerPausedLoadPreservesNewSourceSelectedByPlaybackIntentListener() throws {
      try expectPausedLoadPreservesCallbackSource(
        player: QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        clearsSource: false)
    }

    func testAudioPlayerPausedLoadPreservesClearFromPlaybackIntentListener() throws {
      try expectPausedLoadPreservesCallbackSource(
        player: AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        clearsSource: true)
    }

    func testQueuedPlayerPausedLoadPreservesClearFromPlaybackIntentListener() throws {
      try expectPausedLoadPreservesCallbackSource(
        player: QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        clearsSource: true)
    }

    private func expectPausedLoadAllowsSameIntentCallback(player: AudioPlayer) {
      player.load(item: PlayerArtworkItem(title: "initial"), playWhenReady: true)
      var handledPause = false
      player.event.playWhenReadyChange.addListener(self, onMainQueue: true) { ready in
        guard !ready, !handledPause else { return }
        handledPause = true
        player.pause()
      }

      player.load(item: PlayerArtworkItem(title: "requested"), playWhenReady: false)

      XCTAssertTrue(handledPause)
      XCTAssertEqual(player.currentItem?.getTitle(), "requested")
      XCTAssertFalse(player.playWhenReady)
    }

    func testAudioPlayerPausedLoadContinuesAfterSameIntentPlaybackCallback() {
      expectPausedLoadAllowsSameIntentCallback(
        player: AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()))
    }

    func testQueuedPlayerPausedLoadContinuesAfterSameIntentPlaybackCallback() {
      expectPausedLoadAllowsSameIntentCallback(
        player: QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()))
    }

    func testQueuedPlayerSourceOperationsApplyPlaybackIntentAfterNestedSourceLoad() throws {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      player.add(item: PlayerArtworkItem(title: "first"), playWhenReady: true)
      XCTAssertEqual(player.currentItem?.getTitle(), "first")
      XCTAssertTrue(player.playWhenReady)

      player.add(items: [PlayerArtworkItem(title: "second")], playWhenReady: false)
      XCTAssertEqual(player.items.compactMap { $0.getTitle() }, ["first", "second"])
      XCTAssertEqual(player.currentItem?.getTitle(), "first")
      XCTAssertFalse(player.playWhenReady)

      try player.jumpToItem(atIndex: 1, playWhenReady: true)
      XCTAssertEqual(player.currentItem?.getTitle(), "second")
      XCTAssertTrue(player.playWhenReady)

      player.load(item: PlayerArtworkItem(title: "replacement"), playWhenReady: false)
      XCTAssertEqual(player.items.compactMap { $0.getTitle() }, ["first", "replacement"])
      XCTAssertEqual(player.currentItem?.getTitle(), "replacement")
      XCTAssertFalse(player.playWhenReady)
    }

    private func expectFailedTrackRetriesWithPlayback(
      _ action: (QueuedAudioPlayer) throws -> Void
    ) throws {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      let url = try writePitchAudioFixture()
      defer {
        player.clear()
        try? FileManager.default.removeItem(at: url)
      }
      let failedItem = DefaultAudioItem(audioUrl: url.path, title: "retry", sourceType: .file)
      player.add(item: failedItem, playWhenReady: false)
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      wrapper.itemFailedToPlayToEndTime()
      XCTAssertEqual(player.playerState, .failed)
      let playing = expectation(description: "The failed current track resumes playback")
      player.event.stateChange.addListener(self, onMainQueue: true) { state in
        if state == .playing { playing.fulfill() }
      }

      try action(player)

      XCTAssertTrue((player.currentItem as? DefaultAudioItem) === failedItem)
      XCTAssertNil(player.playbackError)
      guard player.playWhenReady else { return XCTFail("The explicit Play request was ignored") }
      wait(for: [playing], timeout: 5)
    }

    func testAddingUpcomingItemWithAutoplayRetriesTheFailedCurrentTrack() throws {
      try expectFailedTrackRetriesWithPlayback { player in
        player.add(item: PlayerArtworkItem(title: "upcoming"), playWhenReady: true)
        XCTAssertEqual(player.nextItems.compactMap { $0.getTitle() }, ["upcoming"])
      }
    }

    func testJumpingToFailedCurrentIndexWithAutoplayRetriesTheTrack() throws {
      try expectFailedTrackRetriesWithPlayback { player in
        try player.jumpToItem(atIndex: 0, playWhenReady: true)
        XCTAssertEqual(player.currentIndex, 0)
      }
    }

    func testReplacingFailedTrackWithAnotherInvalidSourceDoesNotPlay() {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      player.load(item: DefaultAudioItem(audioUrl: "http://[", sourceType: .stream))
      XCTAssertEqual(player.playerState, .failed)
      let replacementSource = "https://["

      player.load(
        item: DefaultAudioItem(audioUrl: replacementSource, sourceType: .stream),
        playWhenReady: true)

      guard case .invalidSourceUrl(let failedSource)? = player.playbackError else {
        return XCTFail("The invalid replacement source must keep its failure")
      }
      XCTAssertEqual(failedSource, replacementSource)
      XCTAssertFalse(player.playWhenReady)
    }

    func testFailureListenerReplacementReportsFailureEndOnlyForCurrentSource() {
      let player = AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      let originalSource = "http://["
      let replacementSource = "https://["
      var failedSources: [String] = []
      var endedTitles: [String?] = []
      player.event.fail.addListener(self, onMainQueue: true) { [weak player] error in
        guard case .invalidSourceUrl(let source)? = error as? AudioPlayerError.PlaybackError else {
          return XCTFail("Expected the source error")
        }
        failedSources.append(source)
        if source == originalSource {
          player?.load(item: DefaultAudioItem(
            audioUrl: replacementSource, title: "replacement", sourceType: .stream))
        }
      }
      player.event.playbackEnd.addListener(self, onMainQueue: true) { [weak player] reason in
        if reason == .failed {
          endedTitles.append(player?.currentItem?.getTitle())
        }
      }

      player.load(item: DefaultAudioItem(audioUrl: originalSource, title: "original", sourceType: .stream))

      XCTAssertEqual(failedSources, [originalSource, replacementSource])
      XCTAssertEqual(endedTitles, ["replacement"])
    }

    private func expectInvalidAutoplaySourceKeepsFailure(
      player: AudioPlayer, hasPreviousSource: Bool, retryWithPlay: Bool = false
    ) throws {
      let source = "http://["
      XCTAssertNil(URL(string: source))
      if hasPreviousSource {
        player.load(item: PlayerArtworkItem(title: "previous"), playWhenReady: false)
      }
      var failureCount = 0
      let failureReceived = expectation(description: "Invalid source failure delivered")
      failureReceived.assertForOverFulfill = true
      player.event.fail.addListener(self) { _ in
        DispatchQueue.main.async {
          failureCount += 1
          failureReceived.fulfill()
        }
      }
      let invalidItem = DefaultAudioItem(audioUrl: source, title: "invalid", sourceType: .stream)

      player.load(item: invalidItem, playWhenReady: true)

      XCTAssertFalse(player.playWhenReady)
      if retryWithPlay { player.play() }
      XCTAssertTrue((player.currentItem as? DefaultAudioItem) === invalidItem)
      XCTAssertEqual(player.playerState, .failed)
      guard case .invalidSourceUrl(let failedSource)? = player.playbackError else {
        return XCTFail("The invalid source failure must survive the playback request")
      }
      XCTAssertEqual(failedSource, source)
      wait(for: [failureReceived], timeout: 3)
      XCTAssertEqual(failureCount, 1)
      let controller = try XCTUnwrap(player.nowPlayingInfoController as? PlayerNowPlayingController)
      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "invalid")
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      XCTAssertNil(wrapper.asset)
      XCTAssertNil(wrapper.currentItem)
    }

    func testAudioPlayerInvalidAutoplaySourceKeepsFailureWithoutPreviousSource() throws {
      try expectInvalidAutoplaySourceKeepsFailure(
        player: AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        hasPreviousSource: false)
    }

    func testAudioPlayerInvalidAutoplaySourceDoesNotReloadPreviousSource() throws {
      try expectInvalidAutoplaySourceKeepsFailure(
        player: AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        hasPreviousSource: true)
    }

    func testQueuedPlayerInvalidAutoplaySourceKeepsFailureWithoutPreviousSource() throws {
      try expectInvalidAutoplaySourceKeepsFailure(
        player: QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        hasPreviousSource: false)
    }

    func testQueuedPlayerInvalidAutoplaySourceDoesNotReloadPreviousSource() throws {
      try expectInvalidAutoplaySourceKeepsFailure(
        player: QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        hasPreviousSource: true)
    }

    func testAudioPlayerPlayAfterInvalidSourceDoesNotReloadPreviousSource() throws {
      try expectInvalidAutoplaySourceKeepsFailure(
        player: AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        hasPreviousSource: true, retryWithPlay: true)
    }

    func testQueuedPlayerPlayAfterInvalidSourceDoesNotReloadPreviousSource() throws {
      try expectInvalidAutoplaySourceKeepsFailure(
        player: QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        hasPreviousSource: true, retryWithPlay: true)
    }

    private func expectClearPreservesReentrantLoad(player: AudioPlayer) throws {
      let controller = try XCTUnwrap(player.nowPlayingInfoController as? PlayerNowPlayingController)
      player.load(item: PlayerArtworkItem(title: "initial"), playWhenReady: false)
      _ = try installSeekBoundary(on: player)
      let url = try writePitchAudioFixture()
      defer {
        player.clear()
        try? FileManager.default.removeItem(at: url)
      }
      let replacement = DefaultAudioItem(
        audioUrl: url.path, title: "replacement", sourceType: .file)
      var cancellationCount = 0
      var currentTitles: [String?] = []
      let replacementObserved =
        player is QueuedAudioPlayer
        ? expectation(description: "Replacement track event delivered") : nil
      replacementObserved?.assertForOverFulfill = true
      player.event.currentItem.addListener(self) { change in
        DispatchQueue.main.async {
          currentTitles.append(change.item?.getTitle())
          if change.item?.getTitle() == "replacement" { replacementObserved?.fulfill() }
        }
      }
      player.seek(to: 10) { finished in
        XCTAssertFalse(finished)
        cancellationCount += 1
        player.load(item: replacement, playWhenReady: true)
      }

      player.clear()

      XCTAssertEqual(cancellationCount, 1)
      XCTAssertTrue((player.currentItem as? DefaultAudioItem) === replacement)
      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "replacement")
      XCTAssertTrue(player.playWhenReady)
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      XCTAssertEqual((wrapper.asset as? AVURLAsset)?.url, url)
      let installed = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          (wrapper.currentItem?.asset as? AVURLAsset)?.url == url
        }, object: nil)
      wait(for: [installed], timeout: 5)
      XCTAssertTrue(wrapper.currentItem?.asset === wrapper.asset)
      if let queuedPlayer = player as? QueuedAudioPlayer {
        wait(for: [try XCTUnwrap(replacementObserved)], timeout: 3)
        XCTAssertEqual(queuedPlayer.items.count, 1)
        XCTAssertEqual(queuedPlayer.currentIndex, 0)
        XCTAssertEqual(currentTitles, ["replacement"])
      }
      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "replacement")
      XCTAssertTrue(player.playWhenReady)
    }

    func testAudioPlayerClearPreservesReplacementLoadedBySeekCancellation() throws {
      try expectClearPreservesReentrantLoad(
        player: AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()))
    }

    func testQueuedPlayerClearPreservesReplacementLoadedBySeekCancellation() throws {
      try expectClearPreservesReentrantLoad(
        player: QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()))
    }

    private func expectClearAfterSeekCancellationPause(player: AudioPlayer) throws {
      let controller = try XCTUnwrap(player.nowPlayingInfoController as? PlayerNowPlayingController)
      player.load(item: PlayerArtworkItem(title: "initial"), playWhenReady: true)
      _ = try installSeekBoundary(on: player)
      var cancellationCount = 0
      player.seek(to: 10) { finished in
        XCTAssertFalse(finished)
        cancellationCount += 1
        player.pause()
      }

      player.clear()

      XCTAssertEqual(cancellationCount, 1)
      XCTAssertNil(player.currentItem)
      XCTAssertTrue(controller.values.isEmpty)
      XCTAssertFalse(player.playWhenReady)
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      XCTAssertNil(wrapper.asset)
      XCTAssertNil(wrapper.currentItem)
    }

    func testAudioPlayerClearStillClearsMetadataWhenSeekCancellationPauses() throws {
      try expectClearAfterSeekCancellationPause(
        player: AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()))
    }

    func testQueuedPlayerClearStillClearsMetadataWhenSeekCancellationPauses() throws {
      try expectClearAfterSeekCancellationPause(
        player: QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()))
    }

    private func expectNextEventAfterIndexOnlyEdit(
      expectedPreviousIndex: Int, expectedNextTitle: String,
      edit: (QueuedAudioPlayer) throws -> Void
    ) throws {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      let active = PlayerArtworkItem(title: "B")
      player.add(items: [PlayerArtworkItem(title: "A"), active, PlayerArtworkItem(title: "C")])
      try player.jumpToItem(atIndex: 1)
      var changes: [AudioPlayer.CurrentItemEventData] = []
      let nextTrackReceived = expectation(description: "Next track event delivered")
      nextTrackReceived.assertForOverFulfill = true
      player.event.currentItem.addListener(self) { change in
        DispatchQueue.main.async {
          changes.append(change)
          if change.item?.getTitle() == expectedNextTitle { nextTrackReceived.fulfill() }
        }
      }

      try edit(player)

      XCTAssertTrue((player.currentItem as? PlayerArtworkItem) === active)
      XCTAssertEqual(player.currentIndex, expectedPreviousIndex)

      player.next()
      wait(for: [nextTrackReceived], timeout: 3)

      XCTAssertEqual(changes.count, 1)
      let change = try XCTUnwrap(changes.first)
      XCTAssertTrue((change.lastItem as? PlayerArtworkItem) === active)
      XCTAssertEqual(change.lastIndex, expectedPreviousIndex)
      XCTAssertEqual(change.item?.getTitle(), expectedNextTitle)
      XCTAssertEqual(change.index, expectedPreviousIndex + 1)
    }

    func testInsertBeforeActiveItemUpdatesPreviousIndexInNextTrackEvent() throws {
      try expectNextEventAfterIndexOnlyEdit(expectedPreviousIndex: 2, expectedNextTitle: "C") {
        try $0.add(items: [PlayerArtworkItem(title: "inserted")], at: 0)
      }
    }

    func testRemoveBeforeActiveItemUpdatesPreviousIndexInNextTrackEvent() throws {
      try expectNextEventAfterIndexOnlyEdit(expectedPreviousIndex: 0, expectedNextTitle: "C") {
        try $0.removeItem(at: 0)
      }
    }

    func testMoveAcrossActiveItemUpdatesPreviousIndexInNextTrackEvent() throws {
      try expectNextEventAfterIndexOnlyEdit(expectedPreviousIndex: 0, expectedNextTitle: "C") {
        try $0.moveItem(fromIndex: 0, toIndex: 2)
      }
    }

    func testMoveActiveItemUpdatesPreviousIndexInNextTrackEvent() throws {
      try expectNextEventAfterIndexOnlyEdit(expectedPreviousIndex: 0, expectedNextTitle: "A") {
        try $0.moveItem(fromIndex: 1, toIndex: 0)
      }
    }

    func testRemovePreviousItemsUpdatesPreviousIndexInNextTrackEvent() throws {
      try expectNextEventAfterIndexOnlyEdit(expectedPreviousIndex: 0, expectedNextTitle: "C") {
        $0.removePreviousItems()
      }
    }

    func testRemovingActiveItemReportsItsIndexBeforeRemoval() throws {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      let active = PlayerArtworkItem(title: "B")
      player.add(items: [PlayerArtworkItem(title: "A"), active, PlayerArtworkItem(title: "C")])
      try player.jumpToItem(atIndex: 1)
      var changes: [AudioPlayer.CurrentItemEventData] = []
      let replacementReceived = expectation(description: "Track after removal delivered")
      replacementReceived.assertForOverFulfill = true
      player.event.currentItem.addListener(self) { change in
        DispatchQueue.main.async {
          changes.append(change)
          if change.item?.getTitle() == "C" { replacementReceived.fulfill() }
        }
      }

      try player.removeItem(at: 1)
      wait(for: [replacementReceived], timeout: 3)

      XCTAssertEqual(changes.count, 1)
      let change = try XCTUnwrap(changes.first)
      XCTAssertTrue((change.lastItem as? PlayerArtworkItem) === active)
      XCTAssertEqual(change.lastIndex, 1)
      XCTAssertEqual(change.item?.getTitle(), "C")
      XCTAssertEqual(change.index, 1)
    }

    func testRemovingLastActiveItemKeepsItsPreviousIndexWhenQueueWraps() throws {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      let active = PlayerArtworkItem(title: "C")
      player.add(items: [PlayerArtworkItem(title: "A"), PlayerArtworkItem(title: "B"), active])
      try player.jumpToItem(atIndex: 2)
      var changes: [AudioPlayer.CurrentItemEventData] = []
      let replacementReceived = expectation(description: "Track after removal delivered")
      replacementReceived.assertForOverFulfill = true
      player.event.currentItem.addListener(self) { change in
        DispatchQueue.main.async {
          changes.append(change)
          if change.item?.getTitle() == "A" { replacementReceived.fulfill() }
        }
      }

      try player.removeItem(at: 2)
      wait(for: [replacementReceived], timeout: 3)

      XCTAssertEqual(changes.count, 1)
      let change = try XCTUnwrap(changes.first)
      XCTAssertTrue((change.lastItem as? PlayerArtworkItem) === active)
      XCTAssertEqual(change.lastIndex, 2)
      XCTAssertEqual(change.item?.getTitle(), "A")
      XCTAssertEqual(change.index, 0)
    }

    func testReentrantCurrentItemListenerReportsImmediatelyPreviousItem() throws {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      player.load(item: PlayerArtworkItem(title: "A"))
      let second = PlayerArtworkItem(title: "B")
      let third = PlayerArtworkItem(title: "C")
      var changes: [AudioPlayer.CurrentItemEventData] = []
      let changesReceived = expectation(description: "Listener-selected replacement delivered")
      changesReceived.expectedFulfillmentCount = 2
      changesReceived.assertForOverFulfill = true
      player.event.currentItem.addListener(self) { [weak player] change in
        DispatchQueue.main.async {
          changes.append(change)
          changesReceived.fulfill()
          if (change.item as? PlayerArtworkItem) === second {
            player?.load(item: third)
          }
        }
      }

      player.load(item: second)
      wait(for: [changesReceived], timeout: 3)

      XCTAssertEqual(changes.count, 2)
      XCTAssertEqual(changes.first?.item?.getTitle(), "B")
      XCTAssertEqual(changes.first?.lastItem?.getTitle(), "A")
      let lastChange = try XCTUnwrap(changes.last)
      XCTAssertTrue((lastChange.item as? PlayerArtworkItem) === third)
      XCTAssertTrue((lastChange.lastItem as? PlayerArtworkItem) === second)
      XCTAssertEqual(lastChange.lastIndex, 0)
      XCTAssertTrue((player.currentItem as? PlayerArtworkItem) === third)
    }

    func testPlaybackRateTracksPlayingBufferingAndResume() throws {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      _ = try installSeekBoundary(on: player)
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      player.rate = 1.5
      player.play()

      wrapper.player(didChangeTimeControlStatus: .playing)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)

      wrapper.player(didChangeTimeControlStatus: .waitingToPlayAtSpecifiedRate)
      XCTAssertTrue(player.playWhenReady)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)

      wrapper.player(didChangeTimeControlStatus: .playing)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)

      player.pause()
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    }

    func testLateDurationUpdatesNowPlayingWithoutAnotherStateOrRateChange() throws {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      let asset = PlayerDurationAsset(url: URL(fileURLWithPath: "/yrt-tests/duration.wav"))
      let item = AVPlayerItem(asset: asset)
      wrapper.asset = asset
      wrapper.item = item
      wrapper.avPlayer = PlayerSeekBoundary(item: item)
      wrapper.state = .ready
      XCTAssertEqual(controller.values[MPMediaItemPropertyPlaybackDuration] as? Double, 0)
      controller.set(keyValue: NowPlayingInfoProperty.elapsedPlaybackTime(15))
      controller.set(keyValue: NowPlayingInfoProperty.playbackRate(1.5))
      let durationReceived = expectation(description: "Late duration remains observable")
      player.event.updateDuration.addListener(self) { duration in
        XCTAssertEqual(duration, 30)
        durationReceived.fulfill()
      }

      asset.reportedDuration = CMTime(seconds: 30, preferredTimescale: 1000)
      wrapper.item(didUpdateDuration: 30)

      XCTAssertEqual(controller.values[MPMediaItemPropertyPlaybackDuration] as? Double, 30)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 15)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
      XCTAssertEqual(player.playerState, .ready)
      wait(for: [durationReceived], timeout: 3)
    }

    func testUnknownDurationUsesCurrentDurationInsteadOfPublishingNaN() throws {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      _ = try installSeekBoundary(on: player)
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      controller.set(keyValue: MediaItemProperty.duration(30))

      wrapper.item(didUpdateDuration: .nan)

      XCTAssertEqual(controller.values[MPMediaItemPropertyPlaybackDuration] as? Double, 0)
    }

    func testLateDurationLeavesManuallyManagedNowPlayingValuesUntouched() throws {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      player.automaticallyUpdateNowPlayingInfo = false
      _ = try installSeekBoundary(on: player)
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      controller.set(keyValue: MediaItemProperty.duration(119))
      let durationReceived = expectation(description: "Manual mode still emits duration updates")
      player.event.updateDuration.addListener(self) { duration in
        XCTAssertEqual(duration, 30)
        durationReceived.fulfill()
      }

      wrapper.item(didUpdateDuration: 30)

      XCTAssertEqual(controller.values[MPMediaItemPropertyPlaybackDuration] as? Double, 119)
      wait(for: [durationReceived], timeout: 3)
    }

    func testPlaybackRateStopsDuringLoadingStoppedEndedAndFailedStates() throws {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      _ = try installSeekBoundary(on: player)
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      player.play()
      wrapper.player(didChangeTimeControlStatus: .playing)

      player.load(item: PlayerArtworkItem(title: "loading"), playWhenReady: true)
      XCTAssertEqual(player.playerState, .loading)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)

      wrapper.player(didChangeTimeControlStatus: .playing)
      player.stop()
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)

      player.play()
      wrapper.player(didChangeTimeControlStatus: .playing)
      player.AVWrapperItemDidPlayToEndTime()
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)

      wrapper.player(didChangeTimeControlStatus: .playing)
      player.load(item: DefaultAudioItem(audioUrl: "http://[", sourceType: .stream))
      XCTAssertEqual(player.playerState, .failed)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    }

    private func writePitchAudioFixture() throws -> URL {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "player-pitch-\(UUID().uuidString).wav")
      let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
      buffer.frameLength = buffer.frameCapacity
      let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
      samples.initialize(repeating: 0, count: Int(buffer.frameCapacity))
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: buffer)
      return url
    }

    func testAutoplayAppliesConfiguredPitchBeforeItemBecomesReady() throws {
      let player = PlayerPitchObserver(nowPlayingInfoController: PlayerNowPlayingController())
      player.audioTimePitchAlgorithm = .spectral
      let url = try writePitchAudioFixture()
      defer {
        player.clear()
        try? FileManager.default.removeItem(at: url)
      }
      let installed = expectation(description: "Autoplay item installed")
      player.installed = { algorithm in
        XCTAssertEqual(algorithm, .spectral)
        installed.fulfill()
      }

      player.load(
        item: DefaultAudioItem(audioUrl: url.path, sourceType: .file), playWhenReady: true)

      wait(for: [installed], timeout: 5)
      XCTAssertTrue(player.playWhenReady)
    }

    func testAutoplayAppliesItemPitchOverrideBeforeItemBecomesReady() throws {
      let player = PlayerPitchObserver(nowPlayingInfoController: PlayerNowPlayingController())
      player.audioTimePitchAlgorithm = .timeDomain
      let url = try writePitchAudioFixture()
      defer {
        player.clear()
        try? FileManager.default.removeItem(at: url)
      }
      let installed = expectation(description: "Item pitch installed")
      player.installed = { algorithm in
        XCTAssertEqual(algorithm, .varispeed)
        installed.fulfill()
      }
      let item = DefaultAudioItemTimePitching(
        audioUrl: url.path, artist: nil, title: nil, albumTitle: nil, sourceType: .file,
        artwork: nil, audioTimePitchAlgorithm: .varispeed)

      player.load(item: item, playWhenReady: true)

      wait(for: [installed], timeout: 5)
    }

    func testEndListenerReplacementPreservesNewSourceState() throws {
      for player in [
        AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
      ] {
        player.load(item: PlayerArtworkItem(title: "ended"), playWhenReady: true)
        if let queuedPlayer = player as? QueuedAudioPlayer {
          queuedPlayer.add(item: PlayerArtworkItem(title: "upcoming"))
        }
        _ = try installSeekBoundary(on: player)
        player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
          guard reason == .playedUntilEnd else { return }
          player.load(item: PlayerArtworkItem(title: "listener-replacement"))
        }

        player.AVWrapperItemDidPlayToEndTime()

        XCTAssertEqual(player.currentItem?.getTitle(), "listener-replacement")
        XCTAssertEqual(player.playerState, .loading)
        XCTAssertTrue(player.playWhenReady)
        player.clear()
      }
    }

    func testEndListenerClearPreservesEmptyIdlePlayer() throws {
      for player in [
        AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
        QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController()),
      ] {
        player.load(item: PlayerArtworkItem(title: "ended"), playWhenReady: true)
        _ = try installSeekBoundary(on: player)
        player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
          guard reason == .playedUntilEnd else { return }
          player.clear()
        }

        player.AVWrapperItemDidPlayToEndTime()

        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.playerState, .idle)
        XCTAssertTrue(player.playWhenReady)
      }
    }

    func testEndListenerStopPreservesStoppedPlayer() throws {
      let player = AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      player.load(item: PlayerArtworkItem(title: "ended"), playWhenReady: true)
      _ = try installSeekBoundary(on: player)
      player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
        guard reason == .playedUntilEnd else { return }
        player.stop()
      }

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(player.playerState, .stopped)
      XCTAssertFalse(player.playWhenReady)
      player.clear()
    }

    func testEndListenerPausePreservesPausedPlayer() throws {
      let player = AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      player.load(item: PlayerArtworkItem(title: "ended"), playWhenReady: true)
      _ = try installSeekBoundary(on: player)
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      wrapper.state = .playing
      player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
        guard reason == .playedUntilEnd else { return }
        player.pause()
      }

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(player.playerState, .paused)
      XCTAssertFalse(player.playWhenReady)
      player.clear()
    }

    func testEndListenerSeekPreservesCurrentTimeline() throws {
      for relativeSeek in [false, true] {
        let player = AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
        player.load(item: PlayerArtworkItem(title: "ended"), playWhenReady: true)
        let boundary = try installSeekBoundary(on: player)
        player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
          guard reason == .playedUntilEnd else { return }
          if relativeSeek {
            player.seek(by: 12)
          } else {
            player.seek(to: 12)
          }
        }

        player.AVWrapperItemDidPlayToEndTime()

        XCTAssertEqual(player.playerState, .ready)
        XCTAssertEqual(player.pendingSeekPosition, 12)
        XCTAssertEqual(boundary.requestedTimes, [12])
        player.clear()
      }
    }

    func testQueuedEndListenerNextPreservesSelectedItem() throws {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      player.add(
        items: ["A", "B", "C"].map { PlayerArtworkItem(title: $0) }, playWhenReady: true)
      _ = try installSeekBoundary(on: player)
      player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
        guard reason == .playedUntilEnd else { return }
        player.next()
      }

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(player.currentItem?.getTitle(), "B")
      XCTAssertEqual(player.currentIndex, 1)
      XCTAssertEqual(player.playerState, .loading)
      player.clear()
    }

    func testQueuedEndListenerRemovalPreservesSelectedSuccessor() throws {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      player.add(
        items: ["A", "B", "C"].map { PlayerArtworkItem(title: $0) }, playWhenReady: true)
      _ = try installSeekBoundary(on: player)
      player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
        guard reason == .playedUntilEnd else { return }
        do {
          try player.removeItem(at: 0)
        } catch {
          XCTFail("Removing the ended item failed: \(error)")
        }
      }

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(player.items.map { $0.getTitle() }, ["B", "C"])
      XCTAssertEqual(player.currentItem?.getTitle(), "B")
      XCTAssertEqual(player.currentIndex, 0)
      player.clear()
    }

    func testQueuedEndListenerPlayPreservesExplicitCurrentItemPlayback() throws {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      player.add(items: ["A", "B"].map { PlayerArtworkItem(title: $0) }, playWhenReady: true)
      let boundary = try installSeekBoundary(on: player)
      player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
        guard reason == .playedUntilEnd else { return }
        player.play()
      }

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(player.currentItem?.getTitle(), "A")
      XCTAssertEqual(player.currentIndex, 0)
      XCTAssertTrue(player.playWhenReady)
      XCTAssertEqual(boundary.rate, 1)
      player.clear()
    }

    func testQueuedEndListenerSeekPreservesRequestedPositionWithoutRepeating() throws {
      for relativeSeek in [false, true] {
        let (player, boundary) = try makeRepeatingPlayer()
        player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
          guard reason == .playedUntilEnd else { return }
          if relativeSeek {
            player.seek(by: 12)
          } else {
            player.seek(to: 12)
          }
        }

        player.AVWrapperItemDidPlayToEndTime()

        XCTAssertEqual(boundary.requestedTimes, [12])
        XCTAssertEqual(player.pendingSeekPosition, 12)
        XCTAssertTrue(player.playWhenReady)
        player.clear()
      }
    }

    func testQueuedEndListenerNextInSingleItemRepeatSeeksOnlyOnce() throws {
      let (player, boundary) = try makeRepeatingPlayer(mode: .queue)
      player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
        guard reason == .playedUntilEnd else { return }
        player.next()
      }

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(boundary.requestedTimes, [0])
      try XCTUnwrap(boundary.seekCompletions.last)(true)
      drainMainQueue()
      XCTAssertTrue(player.playWhenReady)
      XCTAssertEqual(boundary.rate, 1)
      player.clear()
    }

    func testQueuedEndListenerPausePreventsAutomaticRepeat() throws {
      let (player, boundary) = try makeRepeatingPlayer()
      player.event.playbackEnd.addListener(self, onMainQueue: true) { reason in
        guard reason == .playedUntilEnd else { return }
        player.pause()
      }

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertTrue(boundary.requestedTimes.isEmpty)
      XCTAssertFalse(player.playWhenReady)
      XCTAssertEqual(boundary.rate, 0)
      player.clear()
    }

    func testQueuedNaturalEndAdvancesOnceThenEndsFinalItem() throws {
      let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
      player.add(items: ["A", "B"].map { PlayerArtworkItem(title: $0) }, playWhenReady: true)
      _ = try installSeekBoundary(on: player)

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(player.currentItem?.getTitle(), "B")
      XCTAssertEqual(player.currentIndex, 1)
      XCTAssertEqual(player.playerState, .loading)
      _ = try installSeekBoundary(on: player)

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(player.currentItem?.getTitle(), "B")
      XCTAssertEqual(player.currentIndex, 1)
      XCTAssertEqual(player.playerState, .ended)
      player.clear()
    }

    func testRepeatWaitsForSuccessfulSeekBeforePlaying() throws {
      let (player, boundary) = try makeRepeatingPlayer()

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(boundary.requestedTimes, [0])
      XCTAssertTrue(player.playWhenReady)
      XCTAssertEqual(boundary.rate, 0)
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()
      XCTAssertTrue(player.playWhenReady)
      XCTAssertEqual(boundary.rate, 1)
    }

    func testFailedRepeatSeekDoesNotRestartPlayback() throws {
      let (player, boundary) = try makeRepeatingPlayer()
      player.AVWrapperItemDidPlayToEndTime()

      try XCTUnwrap(boundary.seekCompletions.first)(false)
      drainMainQueue()

      XCTAssertFalse(player.playWhenReady)
      XCTAssertEqual(boundary.rate, 0)
    }

    func testReplaySeekCompletionCannotAuthorizePlaybackDuringOrAfterInterruption() throws {
      for interruptionEndsBeforeSeek in [false, true] {
        let (player, boundary) = try makeRepeatingPlayer()
        player.AVWrapperItemDidPlayToEndTime()
        NotificationCenter.default.post(
          name: AVAudioSession.interruptionNotification, object: nil,
          userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
          ])
        XCTAssertTrue(player.playWhenReady)
        if interruptionEndsBeforeSeek {
          NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
              AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            ])
        }

        try XCTUnwrap(boundary.seekCompletions.first)(true)
        drainMainQueue()

        XCTAssertTrue(player.playWhenReady)
        XCTAssertEqual(boundary.rate, 0)
        if !interruptionEndsBeforeSeek {
          NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
              AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            ])
          XCTAssertEqual(boundary.rate, 0)
        }
        player.play()
        XCTAssertEqual(boundary.rate, 1)
        player.clear()
      }
    }

    func testExplicitPropertyAndToggleCanAuthorizePlaybackDuringInterruption() throws {
      for usesProperty in [false, true] {
        let player = AudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
        let boundary = try installSeekBoundary(on: player)
        player.play()
        NotificationCenter.default.post(
          name: AVAudioSession.interruptionNotification, object: nil,
          userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
          ])
        player.pause()

        if usesProperty {
          player.playWhenReady = true
        } else {
          player.togglePlaying()
        }

        XCTAssertTrue(player.playWhenReady)
        XCTAssertEqual(boundary.rate, 1)
        NotificationCenter.default.post(
          name: AVAudioSession.interruptionNotification, object: nil,
          userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
          ])
        XCTAssertEqual(boundary.rate, 1)
        player.clear()
      }
    }

    func testExplicitPlayAfterRepeatCancellationCanResumeWhenSeekFinishes() throws {
      let (player, boundary) = try makeRepeatingPlayer()
      player.AVWrapperItemDidPlayToEndTime()
      player.repeatMode = .off

      player.play()
      XCTAssertEqual(boundary.rate, 0)
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()

      XCTAssertTrue(player.playWhenReady)
      XCTAssertEqual(boundary.rate, 1)
    }

    func testPauseBeforeQueuedEndNotificationPreventsAutomaticReplay() throws {
      let (player, boundary) = try makeRepeatingPlayer()
      let wrapper = try XCTUnwrap(player.wrapper as? AVPlayerWrapper)
      let item = try XCTUnwrap(wrapper.currentItem)
      let observer = AVPlayerItemNotificationObserver()
      observer.delegate = wrapper
      observer.startObserving(item: item)
      let unexpectedSeek = expectation(description: "Paused playback must not replay")
      unexpectedSeek.isInverted = true
      boundary.onSeek = { unexpectedSeek.fulfill() }

      runOnBackgroundAndWaitForCompletion {
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
      }
      player.pause()
      wait(for: [unexpectedSeek], timeout: 0.1)

      XCTAssertTrue(boundary.requestedTimes.isEmpty)
      XCTAssertFalse(player.playWhenReady)
      observer.stopObservingCurrentItem()
    }

    func testNextInOneItemRepeatingQueuePreservesPausedIntent() throws {
      let (player, boundary) = try makeRepeatingPlayer(mode: .queue)
      player.pause()

      player.next()
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()

      XCTAssertEqual(boundary.requestedTimes, [0])
      XCTAssertFalse(player.playWhenReady)
    }

    func testPauseDuringRepeatSeekKeepsPlaybackPaused() throws {
      let (player, boundary) = try makeRepeatingPlayer()
      player.AVWrapperItemDidPlayToEndTime()

      player.pause()
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()

      XCTAssertFalse(player.playWhenReady)
    }

    func testStopDuringRepeatSeekKeepsPlaybackStopped() throws {
      let (player, boundary) = try makeRepeatingPlayer()
      player.AVWrapperItemDidPlayToEndTime()

      player.stop()
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()

      XCTAssertFalse(player.playWhenReady)
      XCTAssertEqual(player.playerState, .stopped)
    }

    func testClearDuringRepeatSeekKeepsQueueEmptyWithoutLosingPlaybackIntent() throws {
      let (player, boundary) = try makeRepeatingPlayer()
      player.AVWrapperItemDidPlayToEndTime()

      player.clear()
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()

      XCTAssertNil(player.currentItem)
      XCTAssertTrue(player.items.isEmpty)
      XCTAssertNil(player.pendingSeekPosition)
      XCTAssertTrue(player.playWhenReady)
      XCTAssertEqual(boundary.rate, 0)
      XCTAssertEqual(player.playerState, .idle)
    }

    func testClearAndReplacementPreservePlayingAndPausedIntent() throws {
      for playWhenReady in [true, false] {
        let player = QueuedAudioPlayer(nowPlayingInfoController: PlayerNowPlayingController())
        player.add(item: PlayerArtworkItem(title: "original"), playWhenReady: playWhenReady)
        _ = try installSeekBoundary(on: player)

        player.clear()

        XCTAssertNil(player.currentItem)
        XCTAssertTrue(player.items.isEmpty)
        XCTAssertEqual(player.playWhenReady, playWhenReady)

        player.add(item: PlayerArtworkItem(title: "replacement"))

        XCTAssertEqual(player.currentItem?.getTitle(), "replacement")
        XCTAssertEqual(player.playWhenReady, playWhenReady)
        player.stop()
        player.clear()
      }
    }

    func testRepeatedNextInSingleItemQueuePreservesPlayingAndPausedIntent() throws {
      for playWhenReady in [true, false] {
        let (player, boundary) = try makeRepeatingPlayer(mode: .queue)
        if !playWhenReady { player.pause() }

        player.next()
        player.next()

        XCTAssertEqual(boundary.requestedTimes, [0, 0])
        XCTAssertEqual(player.playWhenReady, playWhenReady)
        XCTAssertEqual(boundary.rate, 0)
        try XCTUnwrap(boundary.seekCompletions.first)(true)
        drainMainQueue()
        XCTAssertEqual(player.pendingSeekPosition, 0)
        XCTAssertEqual(boundary.rate, 0)
        try XCTUnwrap(boundary.seekCompletions.last)(true)
        drainMainQueue()

        XCTAssertEqual(player.playWhenReady, playWhenReady)
        XCTAssertEqual(boundary.rate, playWhenReady ? 1 : 0)
        player.stop()
        player.clear()
      }
    }

    func testTurningRepeatOffDuringManualSingleItemSkipPreservesPlayback() throws {
      for backwards in [false, true] {
        let (player, boundary) = try makeRepeatingPlayer(mode: .queue)
        if backwards { player.previous() } else { player.next() }

        XCTAssertEqual(boundary.requestedTimes, [0])
        XCTAssertEqual(boundary.rate, 0)
        player.repeatMode = .off
        try XCTUnwrap(boundary.seekCompletions.first)(true)
        drainMainQueue()

        XCTAssertTrue(player.playWhenReady)
        XCTAssertEqual(boundary.rate, 1)
        player.clear()
      }
    }

    func testSwitchingBetweenTrackAndQueueRepeatKeepsSingleItemRestart() throws {
      for mode in [RepeatMode.track, .queue] {
        let (player, boundary) = try makeRepeatingPlayer(mode: mode)
        player.AVWrapperItemDidPlayToEndTime()

        XCTAssertEqual(boundary.requestedTimes, [0])
        XCTAssertEqual(boundary.rate, 0)
        player.repeatMode = mode == .track ? .queue : .track
        try XCTUnwrap(boundary.seekCompletions.first)(true)
        drainMainQueue()

        XCTAssertTrue(player.playWhenReady)
        XCTAssertEqual(boundary.rate, 1)
        player.clear()
      }
    }

    func testSingleItemRepeatRestartsWhenEndListenerSwitchesRepeatMode() throws {
      for mode in [RepeatMode.track, .queue] {
        let (player, boundary) = try makeRepeatingPlayer(mode: mode)
        player.event.playbackEnd.addListener(self, onMainQueue: true) { [weak player] reason in
          guard reason == .playedUntilEnd else { return }
          player?.repeatMode = mode == .track ? .queue : .track
        }

        player.AVWrapperItemDidPlayToEndTime()

        XCTAssertEqual(boundary.requestedTimes, [0])
        XCTAssertEqual(boundary.rate, 0)
        try XCTUnwrap(boundary.seekCompletions.first)(true)
        drainMainQueue()

        XCTAssertTrue(player.playWhenReady)
        XCTAssertEqual(boundary.rate, 1)
        player.clear()
      }
    }

    func testAppendingAnUpcomingItemDuringQueueRepeatAllowsCurrentTrackToRestart() throws {
      for modeAfterAppend in [RepeatMode.queue, .track] {
        let (player, boundary) = try makeRepeatingPlayer(mode: .queue)
        player.AVWrapperItemDidPlayToEndTime()

        XCTAssertEqual(boundary.requestedTimes, [0])
        XCTAssertEqual(boundary.rate, 0)
        player.add(item: PlayerArtworkItem(title: "upcoming"))
        player.repeatMode = modeAfterAppend
        try XCTUnwrap(boundary.seekCompletions.first)(true)
        drainMainQueue()

        XCTAssertEqual(player.currentItem?.getTitle(), "repeat")
        XCTAssertEqual(player.nextItems.map { $0.getTitle() }, ["upcoming"])
        XCTAssertTrue(player.playWhenReady)
        XCTAssertEqual(boundary.rate, 1)
        player.clear()
      }
    }

    func testSwitchingToQueueRepeatWithUpcomingItemCancelsTrackRestart() throws {
      let (player, boundary) = try makeRepeatingPlayer(mode: .track)
      player.add(item: PlayerArtworkItem(title: "upcoming"))
      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(boundary.requestedTimes, [0])
      XCTAssertEqual(boundary.rate, 0)
      player.repeatMode = .queue
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()

      XCTAssertFalse(player.playWhenReady)
      XCTAssertEqual(boundary.rate, 0)
      player.clear()
    }

    func testTurningRepeatOffDuringSeekWithholdsAutomaticRestart() throws {
      for mode in [RepeatMode.track, .queue] {
        let (player, boundary) = try makeRepeatingPlayer(mode: mode)
        player.AVWrapperItemDidPlayToEndTime()

        XCTAssertEqual(boundary.requestedTimes, [0])
        XCTAssertEqual(boundary.rate, 0)
        player.repeatMode = .off
        try XCTUnwrap(boundary.seekCompletions.first)(true)
        drainMainQueue()

        XCTAssertFalse(player.playWhenReady)
        XCTAssertEqual(boundary.rate, 0)
        player.clear()
      }
    }

    func testLoadingReplacementDuringRepeatSeekPreservesPausedIntent() throws {
      let (player, boundary) = try makeRepeatingPlayer()
      player.AVWrapperItemDidPlayToEndTime()
      let replacement = PlayerArtworkItem(title: "replacement")

      player.load(item: replacement, playWhenReady: false)
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()

      XCTAssertEqual(player.currentItem?.getTitle(), "replacement")
      XCTAssertFalse(player.playWhenReady)
    }

    func testLoadingAutoplayReplacementDuringRepeatSeekKeepsNewPlayingIntent() throws {
      let (player, boundary) = try makeRepeatingPlayer()
      player.AVWrapperItemDidPlayToEndTime()
      let replacement = PlayerArtworkItem(title: "replacement-autoplay")

      player.load(item: replacement, playWhenReady: true)
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()

      XCTAssertEqual(player.currentItem?.getTitle(), "replacement-autoplay")
      XCTAssertTrue(player.playWhenReady)
    }

    func testPendingReplayDoesNotRetainReleasedAudioPlayer() throws {
      var player: QueuedAudioPlayer? = QueuedAudioPlayer(
        nowPlayingInfoController: PlayerNowPlayingController())
      player?.add(item: PlayerArtworkItem(title: "released-repeat"), playWhenReady: true)
      weak var releasedPlayer = player
      let boundary = try installSeekBoundary(on: XCTUnwrap(player))
      player?.repeatMode = .track
      player?.AVWrapperItemDidPlayToEndTime()
      XCTAssertEqual(boundary.requestedTimes, [0])

      player = nil

      XCTAssertNil(releasedPlayer)
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()
    }

    func testSingleItemQueueRepeatWaitsForSeekAndHonorsPause() throws {
      let (player, boundary) = try makeRepeatingPlayer(mode: .queue)

      player.AVWrapperItemDidPlayToEndTime()

      XCTAssertEqual(boundary.requestedTimes, [0])
      XCTAssertTrue(player.playWhenReady)
      XCTAssertEqual(boundary.rate, 0)
      player.pause()
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()
      XCTAssertFalse(player.playWhenReady)
      XCTAssertEqual(player.currentIndex, 0)
    }

    func testSupersedingReplaySeekPreservesPlayingAndPausedIntent() throws {
      for playWhenReady in [true, false] {
        let (player, boundary) = try makeRepeatingPlayer(mode: .queue)
        player.next()
        if !playWhenReady { player.pause() }
        let repeatCompletion = try XCTUnwrap(boundary.seekCompletions.first)

        player.seek(to: 12)

        XCTAssertEqual(player.playWhenReady, playWhenReady)
        XCTAssertEqual(boundary.rate, 0)
        repeatCompletion(true)
        drainMainQueue()
        XCTAssertEqual(player.pendingSeekPosition, 12)
        XCTAssertEqual(boundary.rate, 0)
        try XCTUnwrap(boundary.seekCompletions.last)(true)
        drainMainQueue()

        XCTAssertEqual(player.playWhenReady, playWhenReady)
        XCTAssertEqual(boundary.rate, playWhenReady ? 1 : 0)
        XCTAssertEqual(boundary.requestedTimes, [0, 12])
        player.stop()
        player.clear()
      }
    }

    func testSupersedingReplaySeekCannotBypassInterruptionOrRouteLoss() throws {
      for routeLoss in [false, true] {
        let (player, boundary) = try makeRepeatingPlayer(mode: .queue)
        player.next()
        player.seek(to: 12)
        if routeLoss {
          NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [
              AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason
                .oldDeviceUnavailable.rawValue
            ])
        } else {
          NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
              AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ])
        }

        try XCTUnwrap(boundary.seekCompletions.first)(true)
        try XCTUnwrap(boundary.seekCompletions.last)(true)
        drainMainQueue()

        XCTAssertEqual(player.playWhenReady, !routeLoss)
        XCTAssertEqual(boundary.rate, 0)
        if !routeLoss {
          NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
              AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            ])
          XCTAssertEqual(boundary.rate, 0)
        }
        player.stop()
        player.clear()
      }
    }

    func testCancelledSeekDoesNotChangeNowPlayingElapsedTimeButStillEmitsResult() throws {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let boundary = try installSeekBoundary(on: player)
      controller.set(keyValue: NowPlayingInfoProperty.elapsedPlaybackTime(7))
      let seekEmitted = expectation(description: "Cancelled seek event")
      player.event.seek.addListener(self) { result in
        XCTAssertEqual(result.seconds, 30)
        XCTAssertFalse(result.didFinish)
        seekEmitted.fulfill()
      }

      player.seek(to: 30)
      try XCTUnwrap(boundary.seekCompletions.first)(false)
      wait(for: [seekEmitted], timeout: 2)

      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 7)
    }

    func testSuccessfulSeekUpdatesNowPlayingElapsedTime() throws {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let boundary = try installSeekBoundary(on: player)

      player.seek(to: 30)
      try XCTUnwrap(boundary.seekCompletions.first)(true)
      drainMainQueue()

      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 30)
    }

    func testOldArtworkCannotReplaceNewItemArtwork() {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let first = PlayerArtworkItem(title: "first")
      let second = PlayerArtworkItem(title: "second")
      player.load(item: first)
      player.load(item: second)

      second.artworkRequests[0](makeImage(width: 2))
      first.artworkRequests[0](makeImage(width: 1))
      drainMainQueue()

      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "second")
      XCTAssertEqual(
        (controller.values[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.size.width, 2
      )
    }

    func testNewItemImmediatelyClearsPreviousArtworkBeforeArtworkArrives() {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let first = PlayerArtworkItem(title: "first")
      player.load(item: first)
      first.artworkRequests[0](makeImage(width: 1))
      drainMainQueue()
      XCTAssertNotNil(controller.values[MPMediaItemPropertyArtwork])

      player.load(item: PlayerArtworkItem(title: "second"))

      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "second")
      XCTAssertNil(controller.values[MPMediaItemPropertyArtwork])
    }

    func testSameItemMetadataRefreshKeepsArtworkUntilReplacementArrives() {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let item = PlayerArtworkItem(title: "same")
      player.load(item: item)
      item.artworkRequests[0](makeImage(width: 1))
      drainMainQueue()

      player.loadNowPlayingMetaValues()

      XCTAssertEqual(
        (controller.values[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.size.width, 1
      )
      item.artworkRequests[1](makeImage(width: 2))
      drainMainQueue()
      XCTAssertEqual(
        (controller.values[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.size.width, 2
      )
    }

    func testManualMetadataRefreshLoadsArtworkWhenAutomaticUpdatesAreDisabled() {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      player.automaticallyUpdateNowPlayingInfo = false
      let item = PlayerArtworkItem(title: "manual")
      player.load(item: item)
      XCTAssertTrue(item.artworkRequests.isEmpty)
      XCTAssertNil(controller.values[MPMediaItemPropertyTitle])

      player.loadNowPlayingMetaValues()
      item.artworkRequests[0](makeImage(width: 2))
      drainMainQueue()

      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "manual")
      XCTAssertEqual(
        (controller.values[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.size.width, 2
      )
    }

    func testArtworkAfterClearCannotRestoreNowPlayingInfo() {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let item = PlayerArtworkItem(title: "cleared")
      player.load(item: item)
      player.clear()

      item.artworkRequests[0](makeImage(width: 1))
      drainMainQueue()

      XCTAssertTrue(controller.values.isEmpty)
    }

    func testNewerArtworkRequestForSameItemWins() {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let item = PlayerArtworkItem(title: "refreshed")
      player.load(item: item)
      player.loadNowPlayingMetaValues()

      item.artworkRequests[1](makeImage(width: 2))
      item.artworkRequests[0](makeImage(width: 1))
      drainMainQueue()

      XCTAssertEqual(
        (controller.values[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.size.width, 2
      )
    }

    func testLoadingWithoutAutomaticMetadataInvalidatesOldArtworkRequest() {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let first = PlayerArtworkItem(title: "first")
      player.load(item: first)
      player.automaticallyUpdateNowPlayingInfo = false
      player.load(item: PlayerArtworkItem(title: "second"))

      first.artworkRequests[0](makeImage(width: 1))
      drainMainQueue()

      XCTAssertNil(controller.values[MPMediaItemPropertyArtwork])
    }

    func testDisablingAutomaticMetadataIgnoresPendingArtwork() {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let item = PlayerArtworkItem(title: "disabled")
      player.load(item: item)
      player.automaticallyUpdateNowPlayingInfo = false

      item.artworkRequests[0](makeImage(width: 1))
      drainMainQueue()

      XCTAssertNil(controller.values[MPMediaItemPropertyArtwork])
    }

    func testArtworkCompletionPublishesOnMainThread() {
      let controller = PlayerNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let item = PlayerArtworkItem(title: "background")
      let image = makeImage(width: 1)
      player.load(item: item)
      let delivered = expectation(description: "Artwork callback delivered")

      DispatchQueue.global().async {
        item.artworkRequests[0](image)
        delivered.fulfill()
      }
      wait(for: [delivered], timeout: 2)
      drainMainQueue()

      XCTAssertEqual(controller.artworkThreads, [true, true])
    }
  }
#endif
