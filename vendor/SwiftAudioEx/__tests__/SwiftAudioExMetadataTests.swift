import AVFoundation
import XCTest

private final class ControlledMetadataAsset: AVURLAsset, @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [String: AVKeyValueStatus] = [:]
  private var metadataCompletion: (() -> Void)?
  private var playableCompletion: (() -> Void)?
  private var reads: [(String, Bool)] = []
  var commonItems: [AVMetadataItem] = []
  var locales: [Locale] = []
  var formats: [AVMetadataFormat] = []
  var chapters: [String: [AVTimedMetadataGroup]] = [:]
  var formattedItems: [AVMetadataFormat: [AVMetadataItem]] = [:]
  var assetDuration = CMTime(seconds: 30, preferredTimescale: 1000)
  var onCancel: (() -> Void)?
  var failedFormats: Set<AVMetadataFormat> = []

  var recordedReads: [(String, Bool)] {
    lock.lock()
    defer { lock.unlock() }
    return reads
  }

  private func record(_ key: String) {
    lock.lock()
    reads.append((key, Thread.isMainThread))
    lock.unlock()
  }

  func setStatus(_ status: AVKeyValueStatus, for keys: [String]) {
    lock.lock()
    for key in keys { statuses[key] = status }
    lock.unlock()
  }

  func finishMetadata(status: AVKeyValueStatus = .loaded, loadedKeys: [String] = []) {
    setStatus(
      status,
      for: ["commonMetadata", "availableChapterLocales", "availableMetadataFormats", "duration"])
    setStatus(.loaded, for: loadedKeys)
    metadataCompletion?()
  }

  func finishPlayable(status: AVKeyValueStatus = .loaded) {
    setStatus(status, for: ["playable"])
    playableCompletion?()
  }

  override func loadValuesAsynchronously(
    forKeys keys: [String], completionHandler handler: (() -> Void)? = nil
  ) {
    if keys == ["playable"] { playableCompletion = handler } else { metadataCompletion = handler }
  }

  override func statusOfValue(forKey key: String, error outError: NSErrorPointer)
    -> AVKeyValueStatus
  {
    lock.lock()
    defer { lock.unlock() }
    return statuses[key] ?? .unknown
  }

  override func cancelLoading() {
    onCancel?()
    finishMetadata(status: .cancelled)
    finishPlayable(status: .cancelled)
  }

  override var commonMetadata: [AVMetadataItem] {
    record("commonMetadata")
    return commonItems
  }
  override var availableChapterLocales: [Locale] {
    record("availableChapterLocales")
    return locales
  }
  override var availableMetadataFormats: [AVMetadataFormat] {
    record("availableMetadataFormats")
    return formats
  }
  override var duration: CMTime {
    record("duration")
    return assetDuration
  }
  override var isPlayable: Bool { true }

  override func chapterMetadataGroups(
    withTitleLocale locale: Locale, containingItemsWithCommonKeys commonKeys: [AVMetadataKey]?
  ) -> [AVTimedMetadataGroup] {
    record("chapters")
    return chapters[locale.identifier] ?? []
  }

  override func loadMetadata(
    for format: AVMetadataFormat, completionHandler: @escaping ([AVMetadataItem]?, Error?) -> Void
  ) {
    record("format")
    completionHandler(failedFormats.contains(format) ? nil : formattedItems[format] ?? [], nil)
  }
}

private final class MetadataDelegate: AVPlayerWrapperDelegate {
  var events: [String] = []
  var common: [[AVMetadataItem]] = []
  var chapters: [[AVTimedMetadataGroup]] = []
  var timed: [[AVTimedMetadataGroup]] = []
  var failures: [Error?] = []
  var onEvent: ((String) -> Void)?
  var onSeek: ((Double, Bool) -> Void)?
  func AVWrapper(didChangeState state: AVPlayerWrapperState) {}
  func AVWrapper(secondsElapsed seconds: Double) {}
  func AVWrapper(failedWithError error: Error?) { failures.append(error) }
  func AVWrapper(seekTo seconds: Double, didFinish: Bool) { onSeek?(seconds, didFinish) }
  func AVWrapper(didUpdateDuration duration: Double) {}
  func AVWrapper(didReceiveCommonMetadata metadata: [AVMetadataItem]) {
    XCTAssertTrue(Thread.isMainThread)
    common.append(metadata)
    events.append("common")
    _ = metadata.map { ($0.stringValue, $0.value) }
    onEvent?("common")
  }
  func AVWrapper(didReceiveChapterMetadata metadata: [AVTimedMetadataGroup]) {
    XCTAssertTrue(Thread.isMainThread)
    chapters.append(metadata)
    events.append("chapter")
    _ = metadata.flatMap { $0.items }.map { ($0.stringValue, $0.value) }
    onEvent?("chapter")
  }
  func AVWrapper(didReceiveTimedMetadata metadata: [AVTimedMetadataGroup]) {
    XCTAssertTrue(Thread.isMainThread)
    timed.append(metadata)
    events.append("timed")
    _ = metadata.flatMap { $0.items }.map { ($0.stringValue, $0.value) }
    onEvent?("timed")
  }
  func AVWrapper(didChangePlayWhenReady playWhenReady: Bool) {}
  func AVWrapperItemDidPlayToEndTime() {}
  func AVWrapperItemFailedToPlayToEndTime() {}
  func AVWrapperItemPlaybackStalled() {}
  func AVWrapperDidRecreateAVPlayer() {}
}

final class SwiftAudioExMetadataTests: XCTestCase {
  private let trackURL = URL(fileURLWithPath: "/yrt-tests/metadata-track.mp3")

  private func drainMetadataCallbacks() {
    let drained = expectation(description: "metadata callbacks finish")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  func testInlineCancellationRetiresAssetBeforeCompletionAndNeverReadsMetadataOnMain() {
    let asset = ControlledMetadataAsset(url: trackURL)
    let cancelledItem = ControlledMetadataItem(title: "Cancelled")
    asset.commonItems = [cancelledItem]
    let delegate = MetadataDelegate()
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    var retiredDuringCancellation = false
    asset.onCancel = { retiredDuringCancellation = wrapper.asset == nil && wrapper.item == nil }

    wrapper.unload()
    drainMetadataCallbacks()

    asset.onCancel = nil
    XCTAssertTrue(retiredDuringCancellation)
    XCTAssertTrue(asset.recordedReads.isEmpty)
    XCTAssertTrue(cancelledItem.recordedReads.isEmpty)
    XCTAssertTrue(delegate.events.isEmpty)
    XCTAssertTrue(delegate.failures.isEmpty)
    XCTAssertNil(wrapper.currentItem)
  }
}

private final class ControlledMetadataItem: AVMetadataItem, @unchecked Sendable {
  let template: AVMutableMetadataItem
  private let lock = NSLock()
  private var completion: (() -> Void)?
  private var reads: [(String, Bool)] = []
  var valueStatus: AVKeyValueStatus = .loaded
  var attributesStatus: AVKeyValueStatus = .loaded
  var delaysLoading = false
  var onLoad: (() -> Void)?

  init(title: String, time: Double = 0) {
    template = AVMutableMetadataItem()
    template.identifier = .commonIdentifierTitle
    template.value = title as NSString
    template.locale = Locale(identifier: "cs")
    template.extendedLanguageTag = "cs"
    template.time = CMTime(seconds: time, preferredTimescale: 1000)
    template.duration = CMTime(seconds: 7, preferredTimescale: 1000)
    template.extraAttributes = [AVMetadataExtraAttributeKey(rawValue: "fixture"): "preserved"]
    super.init()
  }

  var recordedReads: [(String, Bool)] {
    lock.lock()
    defer { lock.unlock() }
    return reads
  }

  private func record(_ name: String) {
    lock.lock()
    reads.append((name, Thread.isMainThread))
    lock.unlock()
  }

  func finishLoading() {
    lock.lock()
    let callback = completion
    completion = nil
    lock.unlock()
    callback?()
  }

  override func loadValuesAsynchronously(
    forKeys keys: [String], completionHandler handler: (() -> Void)? = nil
  ) {
    record("load")
    XCTAssertEqual(keys, ["value", "extraAttributes"])
    if delaysLoading {
      lock.lock()
      completion = handler
      lock.unlock()
    } else {
      handler?()
    }
    onLoad?()
  }

  override func statusOfValue(forKey key: String, error outError: NSErrorPointer)
    -> AVKeyValueStatus
  {
    key == "value" ? valueStatus : attributesStatus
  }

  override var value: (NSCopying & NSObjectProtocol)? {
    record("value")
    return template.value
  }
  override var stringValue: String? {
    record("stringValue")
    return template.stringValue
  }
  override func mutableCopy(with zone: NSZone? = nil) -> Any {
    record("copy")
    XCTAssertEqual(valueStatus, .loaded)
    XCTAssertEqual(attributesStatus, .loaded)
    return template.mutableCopy(with: zone)
  }
}

private final class DurationPlayerItem: AVPlayerItem, @unchecked Sendable {
  var itemDuration: CMTime = .indefinite
  var ranges: [NSValue] = []
  override var duration: CMTime { itemDuration }
  override var seekableTimeRanges: [NSValue] { ranges }
}

extension SwiftAudioExMetadataTests {
  func testUnavailableOptionalKeysNeverReadGettersOrFailPlayableLoading() {
    for status in [AVKeyValueStatus.unknown, .loading, .failed, .cancelled] {
      let asset = ControlledMetadataAsset(url: trackURL)
      let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
      let delegate = MetadataDelegate()
      wrapper.delegate = delegate
      wrapper.load(from: trackURL, playWhenReady: false)

      asset.finishMetadata(status: status)
      asset.finishPlayable()
      drainMetadataCallbacks()

      XCTAssertTrue(wrapper.currentItem?.asset === asset)
      XCTAssertTrue(
        asset.recordedReads.isEmpty, "Optional status \(status) must not trigger a getter")
      XCTAssertTrue(delegate.failures.isEmpty)
      XCTAssertTrue(delegate.events.isEmpty)
      wrapper.unload()
    }
  }

  func testLoadedCommonAndEveryChapterLocaleKeepOrderAndEagerMetadataFields() throws {
    let common = ControlledMetadataItem(title: "Episode")
    let artwork = ControlledMetadataItem(title: "Artwork")
    artwork.template.identifier = .commonIdentifierArtwork
    artwork.template.value = Data([0, 1, 255]) as NSData
    let english = ControlledMetadataItem(title: "Introduction", time: 3)
    let czech = ControlledMetadataItem(title: "Úvod", time: 3)
    let asset = ControlledMetadataAsset(url: trackURL)
    asset.commonItems = [common, artwork]
    asset.locales = [Locale(identifier: "en"), Locale(identifier: "cs")]
    let range = CMTimeRange(
      start: CMTime(seconds: 3, preferredTimescale: 1000),
      duration: CMTime(seconds: 7, preferredTimescale: 1000))
    asset.chapters = [
      "en": [AVTimedMetadataGroup(items: [english], timeRange: range)],
      "cs": [AVTimedMetadataGroup(items: [czech], timeRange: range)],
    ]
    asset.formats = [AVMetadataFormat(rawValue: "unused")]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = MetadataDelegate()
    let received = expectation(description: "both chapter locales arrive")
    delegate.onEvent = { [weak delegate] _ in
      if delegate?.chapters.count == 2 { received.fulfill() }
    }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)

    asset.finishMetadata()
    wait(for: [received], timeout: 3)

    XCTAssertEqual(delegate.events, ["common", "chapter", "chapter"])
    let prepared = try XCTUnwrap(delegate.common.first?.first)
    XCTAssertFalse(prepared === common)
    XCTAssertEqual(prepared.stringValue, "Episode")
    XCTAssertEqual(prepared.value as? String, "Episode")
    XCTAssertEqual(delegate.common.first?.last?.value as? Data, Data([0, 1, 255]))
    XCTAssertEqual(delegate.common.first?.last?.identifier, .commonIdentifierArtwork)
    XCTAssertEqual(prepared.identifier, .commonIdentifierTitle)
    XCTAssertEqual(prepared.locale, Locale(identifier: "cs"))
    XCTAssertEqual(prepared.extendedLanguageTag, "cs")
    XCTAssertEqual(
      prepared.extraAttributes?[AVMetadataExtraAttributeKey(rawValue: "fixture")] as? String,
      "preserved")
    XCTAssertEqual(
      delegate.chapters.map { $0.first?.items.first?.stringValue }, ["Introduction", "Úvod"])
    XCTAssertEqual(delegate.chapters.first?.first?.timeRange, range)
    XCTAssertEqual(delegate.chapters.first?.first?.items.first?.time.seconds, 3)
    XCTAssertEqual(delegate.chapters.first?.first?.items.first?.duration.seconds, 7)
    for item in [common, artwork, english, czech] {
      XCTAssertEqual(item.recordedReads.map { $0.0 }, ["load", "copy"])
      XCTAssertFalse(item.recordedReads.contains { $0.1 })
    }
    XCTAssertFalse(asset.recordedReads.contains { $0.1 })
    XCTAssertFalse(
      asset.recordedReads.contains { $0.0 == "availableMetadataFormats" || $0.0 == "format" })
    wrapper.unload()
  }

  func testFormatsFallbackKeepsOrderDurationAndRawValuesWhileDroppingUnloadedItems() throws {
    let valid = ControlledMetadataItem(title: "ID3 title", time: 4)
    let invalid = ControlledMetadataItem(title: "unavailable")
    invalid.attributesStatus = .failed
    let second = ControlledMetadataItem(title: "Second format")
    let firstFormat = AVMetadataFormat(rawValue: "first")
    let secondFormat = AVMetadataFormat(rawValue: "second")
    let asset = ControlledMetadataAsset(url: trackURL)
    asset.formats = [firstFormat, secondFormat]
    asset.formattedItems = [firstFormat: [valid, invalid], secondFormat: [second]]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = MetadataDelegate()
    let received = expectation(description: "all format groups arrive")
    delegate.onEvent = { [weak delegate] _ in if delegate?.timed.count == 2 { received.fulfill() } }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)

    asset.finishMetadata()
    wait(for: [received], timeout: 3)

    XCTAssertEqual(delegate.events, ["timed", "timed"])
    XCTAssertEqual(
      delegate.timed.map { $0.first?.items.map { $0.stringValue } },
      [["ID3 title"], ["Second format"]])
    XCTAssertEqual(delegate.timed.first?.first?.timeRange.duration.seconds, 30)
    XCTAssertEqual(delegate.timed.first?.first?.items.first?.value as? String, "ID3 title")
    XCTAssertEqual(delegate.timed.first?.first?.items.first?.time.seconds, 4)
    XCTAssertEqual(invalid.recordedReads.map { $0.0 }, ["load"])
    XCTAssertFalse(asset.recordedReads.contains { $0.1 })
    XCTAssertTrue(delegate.failures.isEmpty)
    wrapper.unload()
  }

  func testCommonMetadataSurvivesFailedChapterKeyWithoutTreatingItAsAnEmptyLocaleList() {
    let asset = ControlledMetadataAsset(url: trackURL)
    asset.commonItems = [ControlledMetadataItem(title: "Common survives")]
    asset.formats = [AVMetadataFormat(rawValue: "must not load")]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = MetadataDelegate()
    let received = expectation(description: "common metadata arrives")
    delegate.onEvent = { _ in received.fulfill() }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)

    asset.finishMetadata(status: .failed, loadedKeys: ["commonMetadata"])
    wait(for: [received], timeout: 3)

    XCTAssertEqual(delegate.events, ["common"])
    XCTAssertEqual(asset.recordedReads.map { $0.0 }, ["commonMetadata"])
    XCTAssertTrue(delegate.failures.isEmpty)
    wrapper.unload()
  }

  func testSameURLReplacementRejectsLatePreparedMetadataFromOldAsset() {
    let delayed = ControlledMetadataItem(title: "Old")
    delayed.delaysLoading = true
    let started = expectation(description: "old item starts loading")
    delayed.onLoad = { started.fulfill() }
    let oldAsset = ControlledMetadataAsset(url: trackURL)
    oldAsset.commonItems = [delayed]
    let newAsset = ControlledMetadataAsset(url: trackURL)
    newAsset.commonItems = [ControlledMetadataItem(title: "New")]
    var assets = [oldAsset, newAsset]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in assets.removeFirst() })
    let delegate = MetadataDelegate()
    let received = expectation(description: "replacement metadata arrives")
    delegate.onEvent = { _ in received.fulfill() }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    oldAsset.finishMetadata()
    wait(for: [started], timeout: 3)

    wrapper.load(from: trackURL, playWhenReady: false)
    delayed.finishLoading()
    newAsset.finishMetadata()
    wait(for: [received], timeout: 3)
    drainMetadataCallbacks()

    XCTAssertEqual(delegate.events, ["common"])
    XCTAssertEqual(delegate.common.first?.first?.stringValue, "New")
    XCTAssertTrue(wrapper.asset === newAsset)
    wrapper.unload()
  }

  func testDelegateReplacementStopsRemainingChapterEvents() {
    let asset = ControlledMetadataAsset(url: trackURL)
    asset.commonItems = [ControlledMetadataItem(title: "Old")]
    asset.locales = [Locale(identifier: "cs")]
    asset.chapters = [
      "cs": [
        AVTimedMetadataGroup(
          items: [ControlledMetadataItem(title: "Old chapter")], timeRange: .zero)
      ]
    ]
    let nextAsset = ControlledMetadataAsset(url: trackURL)
    var assets = [asset, nextAsset]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in assets.removeFirst() })
    let delegate = MetadataDelegate()
    let replaced = expectation(description: "delegate replaces its track")
    delegate.onEvent = { event in
      if event == "common" {
        wrapper.load(from: self.trackURL, playWhenReady: false)
        replaced.fulfill()
      }
    }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)

    asset.finishMetadata()
    wait(for: [replaced], timeout: 3)
    drainMetadataCallbacks()

    XCTAssertEqual(delegate.events, ["common"])
    XCTAssertTrue(wrapper.asset === nextAsset)
    wrapper.unload()
  }

  func testTimedMetadataPreparesEagerValuesAndDropsRetiredAssetResults() {
    let oldItem = ControlledMetadataItem(title: "Old live title")
    oldItem.delaysLoading = true
    let started = expectation(description: "old timed metadata starts loading")
    oldItem.onLoad = { started.fulfill() }
    let oldAsset = ControlledMetadataAsset(url: trackURL)
    let newAsset = ControlledMetadataAsset(url: trackURL)
    var assets = [oldAsset, newAsset]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in assets.removeFirst() })
    let delegate = MetadataDelegate()
    let received = expectation(description: "new timed metadata arrives")
    delegate.onEvent = { _ in received.fulfill() }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.item(didReceiveTimedMetadata: [AVTimedMetadataGroup(items: [oldItem], timeRange: .zero)]
    )
    wait(for: [started], timeout: 3)
    wrapper.load(from: trackURL, playWhenReady: false)
    oldItem.finishLoading()
    let newItem = ControlledMetadataItem(title: "Live title", time: 120)
    let liveRange = CMTimeRange(
      start: CMTime(seconds: 120, preferredTimescale: 1000), duration: .indefinite)

    wrapper.item(didReceiveTimedMetadata: [
      AVTimedMetadataGroup(items: [newItem], timeRange: liveRange)
    ])
    wait(for: [received], timeout: 3)
    drainMetadataCallbacks()

    XCTAssertEqual(delegate.events, ["timed"])
    XCTAssertEqual(delegate.timed.first?.first?.items.first?.stringValue, "Live title")
    XCTAssertEqual(delegate.timed.first?.first?.items.first?.value as? String, "Live title")
    XCTAssertEqual(delegate.timed.first?.first?.timeRange, liveRange)
    XCTAssertEqual(newItem.recordedReads.map { $0.0 }, ["load", "copy"])
    XCTAssertFalse(newItem.recordedReads.contains { $0.1 })
    wrapper.unload()
  }

  func testDurationReadsAssetOnlyWhenLoadedAndPreservesItemLiveAndZeroFallbacks() {
    let asset = ControlledMetadataAsset(url: trackURL)
    let item = DurationPlayerItem(asset: asset)
    let wrapper = AVPlayerWrapper()
    wrapper.avPlayer.replaceCurrentItem(with: item)
    item.itemDuration = CMTime(seconds: 12, preferredTimescale: 1000)

    XCTAssertEqual(wrapper.duration, 12)
    XCTAssertFalse(asset.recordedReads.contains { $0.0 == "duration" })
    item.itemDuration = .indefinite
    item.ranges = [
      NSValue(
        timeRange: CMTimeRange(
          start: .zero, duration: CMTime(seconds: 180, preferredTimescale: 1000)))
    ]
    XCTAssertEqual(wrapper.duration, 180)
    item.ranges = []
    XCTAssertEqual(wrapper.duration, 0)
    asset.setStatus(.loaded, for: ["duration"])
    XCTAssertEqual(wrapper.duration, 30)
    asset.assetDuration = .indefinite
    item.itemDuration = CMTime(seconds: 19, preferredTimescale: 1000)
    XCTAssertEqual(wrapper.duration, 19)
    wrapper.avPlayer.replaceCurrentItem(with: nil)
  }

  func testPlayableInstallsAndDeferredSeekCompletesWhileMetadataIsPending() throws {
    let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-audio-metadata-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
    buffer.frameLength = 80_000
    buffer.floatChannelData?.pointee.initialize(repeating: 0, count: 80_000)
    let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
    try file.write(from: buffer)
    let asset = ControlledMetadataAsset(url: audioURL)
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = MetadataDelegate()
    let sought = expectation(description: "deferred initial seek completes")
    delegate.onSeek = { seconds, finished in
      XCTAssertEqual(seconds, 2)
      XCTAssertTrue(finished)
      sought.fulfill()
    }
    wrapper.delegate = delegate
    wrapper.load(from: audioURL, playWhenReady: false, initialTime: 2)
    XCTAssertNil(wrapper.currentItem)

    asset.finishPlayable()
    wait(for: [sought], timeout: 8)

    XCTAssertTrue(wrapper.currentItem?.asset === asset)
    XCTAssertEqual(wrapper.currentTime, 2, accuracy: 0.1)
    XCTAssertTrue(delegate.events.isEmpty)
    XCTAssertTrue(delegate.failures.isEmpty)
    wrapper.unload()
  }
}

extension SwiftAudioExMetadataTests {
  func testUnavailableItemValuesAndAttributesNeverForceLazyCopy() {
    let statuses: [AVKeyValueStatus] = [.unknown, .loading, .failed, .cancelled]
    let unavailableValues = statuses.map { status -> ControlledMetadataItem in
      let item = ControlledMetadataItem(title: "unavailable value")
      item.valueStatus = status
      return item
    }
    let unavailableAttributes = statuses.map { status -> ControlledMetadataItem in
      let item = ControlledMetadataItem(title: "unavailable attributes")
      item.attributesStatus = status
      return item
    }
    let asset = ControlledMetadataAsset(url: trackURL)
    asset.commonItems =
      unavailableValues + unavailableAttributes + [ControlledMetadataItem(title: "Available")]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = MetadataDelegate()
    let received = expectation(description: "only available metadata arrives")
    delegate.onEvent = { _ in received.fulfill() }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)

    asset.finishMetadata()
    wait(for: [received], timeout: 3)

    XCTAssertEqual(delegate.common.first?.map { $0.stringValue }, ["Available"])
    for item in unavailableValues + unavailableAttributes {
      XCTAssertEqual(item.recordedReads.map { $0.0 }, ["load"])
    }
    XCTAssertTrue(delegate.failures.isEmpty)
    wrapper.unload()
  }

  func testFailedFormatAndUnloadedDurationKeepCommonAndOtherFormatsNonfatal() {
    let failedFormat = AVMetadataFormat(rawValue: "failed")
    let goodFormat = AVMetadataFormat(rawValue: "good")
    let asset = ControlledMetadataAsset(url: trackURL)
    asset.commonItems = [ControlledMetadataItem(title: "Common")]
    asset.formats = [failedFormat, goodFormat]
    asset.failedFormats = [failedFormat]
    asset.formattedItems = [goodFormat: [ControlledMetadataItem(title: "Timed")]]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = MetadataDelegate()
    let received = expectation(description: "common and available format arrive")
    delegate.onEvent = { [weak delegate] _ in if delegate?.timed.count == 1 { received.fulfill() } }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)

    asset.finishMetadata(
      status: .failed,
      loadedKeys: ["commonMetadata", "availableChapterLocales", "availableMetadataFormats"])
    wait(for: [received], timeout: 3)

    XCTAssertEqual(delegate.events, ["common", "timed"])
    XCTAssertEqual(delegate.timed.first?.first?.items.first?.stringValue, "Timed")
    XCTAssertEqual(delegate.timed.first?.first?.timeRange.isValid, false)
    XCTAssertFalse(asset.recordedReads.contains { $0.0 == "duration" })
    XCTAssertTrue(delegate.failures.isEmpty)
    wrapper.unload()
  }
}

extension SwiftAudioExMetadataTests {
  func testTimedMetadataPreservesEveryBatchInArrivalOrderWhenFirstValueIsDelayed() {
    let first = ControlledMetadataItem(title: "First")
    first.delaysLoading = true
    let started = expectation(description: "first live batch starts")
    first.onLoad = { started.fulfill() }
    let second = ControlledMetadataItem(title: "Second")
    let asset = ControlledMetadataAsset(url: trackURL)
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in asset })
    let delegate = MetadataDelegate()
    let received = expectation(description: "both live batches arrive")
    delegate.onEvent = { [weak delegate] _ in if delegate?.timed.count == 2 { received.fulfill() } }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.item(didReceiveTimedMetadata: [AVTimedMetadataGroup(items: [first], timeRange: .zero)])
    wait(for: [started], timeout: 3)

    wrapper.item(didReceiveTimedMetadata: [AVTimedMetadataGroup(items: [second], timeRange: .zero)])
    drainMetadataCallbacks()
    XCTAssertTrue(delegate.events.isEmpty)
    first.finishLoading()
    wait(for: [received], timeout: 3)

    XCTAssertEqual(delegate.timed.map { $0.first?.items.first?.stringValue }, ["First", "Second"])
    wrapper.unload()
  }

  func testRetiredTimedCompletionCannotReleaseReplacementQueueOrPublishItsPendingBatch() {
    let oldFirst = ControlledMetadataItem(title: "Old first")
    oldFirst.delaysLoading = true
    let oldStarted = expectation(description: "old live batch starts")
    oldFirst.onLoad = { oldStarted.fulfill() }
    let oldSecond = ControlledMetadataItem(title: "Old second")
    let newFirst = ControlledMetadataItem(title: "New first")
    newFirst.delaysLoading = true
    let newStarted = expectation(description: "new live batch starts")
    newFirst.onLoad = { newStarted.fulfill() }
    let newSecond = ControlledMetadataItem(title: "New second")
    var assets = [ControlledMetadataAsset(url: trackURL), ControlledMetadataAsset(url: trackURL)]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in assets.removeFirst() })
    let delegate = MetadataDelegate()
    let received = expectation(description: "only new live batches arrive in order")
    delegate.onEvent = { [weak delegate] _ in if delegate?.timed.count == 2 { received.fulfill() } }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.item(didReceiveTimedMetadata: [
      AVTimedMetadataGroup(items: [oldFirst], timeRange: .zero)
    ])
    wait(for: [oldStarted], timeout: 3)
    wrapper.item(didReceiveTimedMetadata: [
      AVTimedMetadataGroup(items: [oldSecond], timeRange: .zero)
    ])
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.item(didReceiveTimedMetadata: [
      AVTimedMetadataGroup(items: [newFirst], timeRange: .zero)
    ])
    wait(for: [newStarted], timeout: 3)
    wrapper.item(didReceiveTimedMetadata: [
      AVTimedMetadataGroup(items: [newSecond], timeRange: .zero)
    ])

    oldFirst.finishLoading()
    drainMetadataCallbacks()
    XCTAssertTrue(delegate.events.isEmpty)
    newFirst.finishLoading()
    wait(for: [received], timeout: 3)

    XCTAssertEqual(
      delegate.timed.map { $0.first?.items.first?.stringValue }, ["New first", "New second"])
    XCTAssertTrue(oldSecond.recordedReads.isEmpty)
    wrapper.unload()
  }
}

extension SwiftAudioExMetadataTests {
  func testTimedDelegateReplacementKeepsReplacementBatchesInOrder() {
    let oldFirst = ControlledMetadataItem(title: "Old first")
    oldFirst.delaysLoading = true
    let oldStarted = expectation(description: "old first batch starts")
    oldFirst.onLoad = { oldStarted.fulfill() }
    let oldSecond = ControlledMetadataItem(title: "Old second")
    let newFirst = ControlledMetadataItem(title: "New first")
    newFirst.delaysLoading = true
    let newStarted = expectation(description: "replacement first batch starts")
    newFirst.onLoad = { newStarted.fulfill() }
    let newSecond = ControlledMetadataItem(title: "New second")
    var assets = [ControlledMetadataAsset(url: trackURL), ControlledMetadataAsset(url: trackURL)]
    let wrapper = AVPlayerWrapper(makeAsset: { _, _ in assets.removeFirst() })
    let delegate = MetadataDelegate()
    let received = expectation(description: "replacement batches arrive in order")
    delegate.onEvent = { [weak delegate] _ in
      if delegate?.timed.count == 1 {
        wrapper.load(from: self.trackURL, playWhenReady: false)
        wrapper.item(didReceiveTimedMetadata: [
          AVTimedMetadataGroup(items: [newFirst], timeRange: .zero)
        ])
        wrapper.item(didReceiveTimedMetadata: [
          AVTimedMetadataGroup(items: [newSecond], timeRange: .zero)
        ])
      } else if delegate?.timed.count == 3 {
        received.fulfill()
      }
    }
    wrapper.delegate = delegate
    wrapper.load(from: trackURL, playWhenReady: false)
    wrapper.item(didReceiveTimedMetadata: [
      AVTimedMetadataGroup(items: [oldFirst], timeRange: .zero)
    ])
    wait(for: [oldStarted], timeout: 3)
    wrapper.item(didReceiveTimedMetadata: [
      AVTimedMetadataGroup(items: [oldSecond], timeRange: .zero)
    ])

    oldFirst.finishLoading()
    wait(for: [newStarted], timeout: 3)
    drainMetadataCallbacks()
    XCTAssertEqual(delegate.timed.count, 1)
    newFirst.finishLoading()
    wait(for: [received], timeout: 3)

    XCTAssertEqual(
      delegate.timed.map { $0.first?.items.first?.stringValue },
      ["Old first", "New first", "New second"])
    XCTAssertTrue(oldSecond.recordedReads.isEmpty)
    wrapper.unload()
  }
}
