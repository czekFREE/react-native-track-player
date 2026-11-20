#if os(iOS)
  import Foundation
  import MediaPlayer
  import UIKit
  import XCTest

  private final class MetadataNowPlayingController: NowPlayingInfoControllerProtocol {
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

    func clear() { values = [:] }
  }

  private final class MetadataArtworkItem: DefaultAudioItem {
    var artworkRequests: [(UIImage?) -> Void] = []

    init(title: String) {
      super.init(audioUrl: "/yrt-tests/\(title).wav", title: title, sourceType: .file)
    }

    override func getArtwork(_ handler: @escaping (UIImage?) -> Void) {
      artworkRequests.append(handler)
    }
  }

  private final class MetadataArtworkURLProtocol: URLProtocol, @unchecked Sendable {
    static var onStart: ((MetadataArtworkURLProtocol) -> Void)?
    private let stopLock = NSLock()
    private var onStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
      request.url?.host == "artwork.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() { Self.onStart?(self) }

    override func stopLoading() {
      stopLock.lock()
      let stopped = onStop
      onStop = nil
      stopLock.unlock()
      stopped?()
    }

    func observeStop(_ observer: @escaping () -> Void) {
      stopLock.lock()
      defer { stopLock.unlock() }
      onStop = observer
    }

    func finish(data: Data) throws {
      let url = try XCTUnwrap(request.url)
      let response = try XCTUnwrap(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  private final class MetadataSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let invalidated: XCTestExpectation

    init(invalidated: XCTestExpectation) { self.invalidated = invalidated }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
      invalidated.fulfill()
    }
  }

  final class MetadataTests: XCTestCase {
    private var session: URLSession?
    private var sessionInvalidated: XCTestExpectation?
    private let requestLock = NSLock()
    private var requests: [MetadataArtworkURLProtocol] = []

    override func tearDown() {
      session?.invalidateAndCancel()
      MetadataArtworkURLProtocol.onStart = nil
      super.tearDown()
    }

    private func makeSession(
      expectedRequests: Int, onStart: ((MetadataArtworkURLProtocol) -> Void)? = nil
    ) -> (URLSession, XCTestExpectation) {
      let started = expectation(description: "Artwork requests started")
      started.expectedFulfillmentCount = expectedRequests
      let invalidated = expectation(description: "Artwork requests completed")
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [MetadataArtworkURLProtocol.self]
      let session = URLSession(
        configuration: configuration,
        delegate: MetadataSessionDelegate(invalidated: invalidated), delegateQueue: nil)
      self.session = session
      sessionInvalidated = invalidated
      MetadataArtworkURLProtocol.onStart = { [weak self] request in
        guard let self = self else { return }
        self.requestLock.lock()
        self.requests.append(request)
        self.requestLock.unlock()
        onStart?(request)
        started.fulfill()
      }
      return (session, started)
    }

    private func request(path: String) throws -> MetadataArtworkURLProtocol {
      requestLock.lock()
      defer { requestLock.unlock() }
      return try XCTUnwrap(requests.first { $0.request.url?.path == path })
    }

    private func expectCancellation(path: String) throws -> XCTestExpectation {
      let cancelled = expectation(description: "Superseded download stopped for \(path)")
      try request(path: path).observeStop { cancelled.fulfill() }
      return cancelled
    }

    private func finishSession() throws {
      try XCTUnwrap(session).finishTasksAndInvalidate()
      wait(for: [try XCTUnwrap(sessionInvalidated)], timeout: 5)
      drainMainQueue()
    }

    private func drainMainQueue() {
      let drained = expectation(description: "Main queue drained")
      DispatchQueue.main.async { drained.fulfill() }
      wait(for: [drained], timeout: 2)
    }

    private func image(width: CGFloat) -> UIImage {
      let format = UIGraphicsImageRendererFormat.default()
      format.scale = 1
      return UIGraphicsImageRenderer(size: CGSize(width: width, height: 1), format: format).image {
        context in
        UIColor.blue.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
      }
    }

    private func imageData(width: CGFloat) throws -> Data {
      try XCTUnwrap(image(width: width).pngData())
    }

    private func artworkWidth(_ controller: MetadataNowPlayingController) -> CGFloat? {
      (controller.values[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.size.width
    }

    func testSourceReplacementCancelsExplicitArtworkAndPublishesNewArtwork() throws {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      player.load(item: MetadataArtworkItem(title: "first"))
      let (session, started) = makeSession(expectedRequests: 1)
      Metadata.update(
        for: player, with: ["artwork": "https://artwork.invalid/first.png"], urlSession: session)
      wait(for: [started], timeout: 5)
      let cancelled = try expectCancellation(path: "/first.png")
      let second = MetadataArtworkItem(title: "second")

      player.load(item: second)
      second.artworkRequests[0](image(width: 2))
      wait(for: [cancelled], timeout: 5)
      try finishSession()

      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "second")
      XCTAssertEqual(artworkWidth(controller), 2)
    }

    func testPendingDefaultArtworkCannotReplaceExplicitMetadataArtwork() throws {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let item = MetadataArtworkItem(title: "track")
      player.load(item: item)
      let (session, started) = makeSession(expectedRequests: 1)
      Metadata.update(
        for: player, with: ["artwork": "https://artwork.invalid/explicit.png"], urlSession: session)
      wait(for: [started], timeout: 5)

      try request(path: "/explicit.png").finish(data: imageData(width: 2))
      try finishSession()
      item.artworkRequests[0](image(width: 1))
      drainMainQueue()

      XCTAssertEqual(artworkWidth(controller), 2)
      XCTAssertTrue(controller.artworkThreads.allSatisfy { $0 })
    }

    func testNewerExplicitArtworkCancelsThePreviousDownload() throws {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let firstStarted = expectation(description: "First artwork request started")
      let (session, started) = makeSession(expectedRequests: 2) { request in
        if request.request.url?.path == "/first.png" { firstStarted.fulfill() }
      }
      Metadata.update(
        for: player, with: ["artwork": "https://artwork.invalid/first.png"], urlSession: session)
      wait(for: [firstStarted], timeout: 5)
      let cancelled = try expectCancellation(path: "/first.png")

      Metadata.update(
        for: player, with: ["artwork": "https://artwork.invalid/second.png"], urlSession: session)
      wait(for: [started, cancelled], timeout: 5)

      try request(path: "/second.png").finish(data: imageData(width: 2))
      try finishSession()

      XCTAssertEqual(artworkWidth(controller), 2)
    }

    func testClearCancelsPendingExplicitMetadataArtwork() throws {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let (session, started) = makeSession(expectedRequests: 1)
      Metadata.update(
        for: player, with: ["artwork": "https://artwork.invalid/first.png"], urlSession: session)
      wait(for: [started], timeout: 5)
      let cancelled = try expectCancellation(path: "/first.png")

      player.clear()
      wait(for: [cancelled], timeout: 5)
      try finishSession()

      XCTAssertTrue(controller.values.isEmpty)
    }

    func testReleasingPlayerCancelsPendingArtwork() throws {
      let controller = MetadataNowPlayingController()
      var player: AudioPlayer? = AudioPlayer(nowPlayingInfoController: controller)
      weak var releasedPlayer = player
      let (session, started) = makeSession(expectedRequests: 1)
      Metadata.update(
        for: try XCTUnwrap(player), with: ["artwork": "https://artwork.invalid/released.png"],
        urlSession: session)
      wait(for: [started], timeout: 5)
      let cancelled = try expectCancellation(path: "/released.png")

      player = nil
      wait(for: [cancelled], timeout: 5)
      try finishSession()

      XCTAssertNil(releasedPlayer)
      XCTAssertNil(artworkWidth(controller))
    }

    func testDifferentPlayersKeepIndependentArtworkRequests() throws {
      let firstController = MetadataNowPlayingController()
      let secondController = MetadataNowPlayingController()
      let first = AudioPlayer(nowPlayingInfoController: firstController)
      let second = AudioPlayer(nowPlayingInfoController: secondController)
      let (session, started) = makeSession(expectedRequests: 2)
      Metadata.update(
        for: first, with: ["artwork": "https://artwork.invalid/first.png"], urlSession: session)
      Metadata.update(
        for: second, with: ["artwork": "https://artwork.invalid/second.png"], urlSession: session)
      wait(for: [started], timeout: 5)
      let cancelled = try expectCancellation(path: "/first.png")

      first.clear()
      wait(for: [cancelled], timeout: 5)
      try request(path: "/second.png").finish(data: imageData(width: 2))
      try finishSession()

      XCTAssertNil(artworkWidth(firstController))
      XCTAssertEqual(artworkWidth(secondController), 2)
    }

    func testLocalArtworkAndExplicitMetadataWorkWhenAutomaticUpdatesAreDisabled() throws {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      player.automaticallyUpdateNowPlayingInfo = false
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "metadata-\(UUID().uuidString).png")
      try imageData(width: 3).write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }

      Metadata.update(
        for: player,
        with: [
          "title": "Explicit title", "artist": "Artist", "album": "Album", "duration": 120.0,
          "elapsedTime": 15.0, "isLiveStream": true, "artwork": url.absoluteString,
        ])
      drainMainQueue()

      XCTAssertEqual(artworkWidth(controller), 3)
      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "Explicit title")
      XCTAssertEqual(controller.values[MPMediaItemPropertyArtist] as? String, "Artist")
      XCTAssertEqual(controller.values[MPMediaItemPropertyAlbumTitle] as? String, "Album")
      XCTAssertEqual(controller.values[MPMediaItemPropertyPlaybackDuration] as? Double, 120)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 15)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
    }

    func testExplicitNullScalarsClearPublishedValuesAndPreservePendingArtwork() throws {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let (session, started) = makeSession(expectedRequests: 1)
      Metadata.update(
        for: player,
        with: [
          "title": "Title", "artist": "Artist", "album": "Album", "duration": 120.0,
          "elapsedTime": 15.0, "isLiveStream": true,
          "artwork": "https://artwork.invalid/pending.png",
        ], urlSession: session)
      wait(for: [started], timeout: 5)

      Metadata.update(
        for: player,
        with: [
          "title": NSNull(), "artist": NSNull(), "album": NSNull(), "duration": NSNull(),
          "elapsedTime": NSNull(), "isLiveStream": NSNull(),
        ])
      Metadata.update(for: player, with: [:])

      for key in [
        MPMediaItemPropertyTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle,
        MPMediaItemPropertyPlaybackDuration, MPNowPlayingInfoPropertyElapsedPlaybackTime,
        MPNowPlayingInfoPropertyIsLiveStream,
      ] {
        XCTAssertNil(controller.values[key], "Explicit null must clear \(key)")
      }
      try request(path: "/pending.png").finish(data: imageData(width: 2))
      try finishSession()
      XCTAssertEqual(artworkWidth(controller), 2)

      Metadata.update(
        for: player, with: ["duration": 0.0, "elapsedTime": 0.0, "isLiveStream": false])
      Metadata.update(for: player, with: ["title": "New title"])

      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "New title")
      XCTAssertNil(controller.values[MPMediaItemPropertyArtist])
      XCTAssertNil(controller.values[MPMediaItemPropertyAlbumTitle])
      XCTAssertEqual(controller.values[MPMediaItemPropertyPlaybackDuration] as? Double, 0)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, false)
      XCTAssertEqual(artworkWidth(controller), 2)
    }

    func testPartialMetadataUpdatesPreservePublishedArtwork() {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      player.loadArtwork { $0(image(width: 1)) }
      drainMainQueue()

      Metadata.update(for: player, with: ["title": "Updated title"])
      drainMainQueue()

      XCTAssertEqual(artworkWidth(controller), 1)
      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "Updated title")

      Metadata.update(for: player, with: ["elapsedTime": 15.0])
      drainMainQueue()

      XCTAssertEqual(artworkWidth(controller), 1)
      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "Updated title")
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 15)
    }

    func testPartialMetadataUpdatePreservesPendingDefaultArtwork() {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let item = MetadataArtworkItem(title: "track")
      player.load(item: item)

      Metadata.update(for: player, with: ["title": "Updated title"])
      item.artworkRequests[0](image(width: 2))
      drainMainQueue()

      XCTAssertEqual(artworkWidth(controller), 2)
      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "Updated title")
    }

    func testPartialMetadataUpdatePreservesPendingExplicitArtwork() throws {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let (session, started) = makeSession(expectedRequests: 1)
      Metadata.update(
        for: player, with: ["artwork": "https://artwork.invalid/explicit.png"], urlSession: session)
      wait(for: [started], timeout: 5)

      Metadata.update(for: player, with: ["elapsedTime": 15.0])
      try request(path: "/explicit.png").finish(data: imageData(width: 2))
      try finishSession()

      XCTAssertEqual(artworkWidth(controller), 2)
      XCTAssertEqual(controller.values[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 15)
    }

    func testExplicitNullArtworkClearsImageAndInvalidatesPendingDefaultArtwork() {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      let item = MetadataArtworkItem(title: "track")
      player.load(item: item)
      item.artworkRequests[0](image(width: 1))
      drainMainQueue()
      player.loadNowPlayingMetaValues()

      Metadata.update(for: player, with: ["artwork": NSNull()])
      drainMainQueue()
      XCTAssertNil(artworkWidth(controller))

      item.artworkRequests[1](image(width: 2))
      drainMainQueue()

      XCTAssertNil(artworkWidth(controller))
      XCTAssertEqual(controller.values[MPMediaItemPropertyTitle] as? String, "track")
    }

    func testExplicitNullArtworkClearsImageAndCancelsPendingExplicitArtwork() throws {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      player.loadArtwork { $0(image(width: 1)) }
      drainMainQueue()
      let (session, started) = makeSession(expectedRequests: 1)
      Metadata.update(
        for: player, with: ["artwork": "https://artwork.invalid/explicit.png"], urlSession: session)
      wait(for: [started], timeout: 5)
      let cancelled = try expectCancellation(path: "/explicit.png")

      Metadata.update(for: player, with: ["artwork": NSNull()])
      wait(for: [cancelled], timeout: 5)
      try finishSession()

      XCTAssertNil(artworkWidth(controller))
    }

    func testTrackPartialMetadataUpdatesPreserveOmittedFieldsAndSerializedValues() throws {
      let original: [String: Any] = [
        "url": "https://audio.invalid/track.mp3", "title": "Original title", "artist": "Artist",
        "date": "2026-11-19", "album": "Album", "genre": "Spoken", "description": "Description",
        "duration": 120.0, "artwork": "https://artwork.invalid/original.png", "isLiveStream": true,
      ]
      let track = try XCTUnwrap(Track(dictionary: original))

      track.updateMetadata(dictionary: ["title": "Updated title"])
      track.updateMetadata(dictionary: ["elapsedTime": 15.0])

      XCTAssertEqual(track.title, "Updated title")
      XCTAssertEqual(track.artist, "Artist")
      XCTAssertEqual(track.date, "2026-11-19")
      XCTAssertEqual(track.album, "Album")
      XCTAssertEqual(track.genre, "Spoken")
      XCTAssertEqual(track.desc, "Description")
      XCTAssertEqual(track.duration, 120)
      XCTAssertEqual(track.artworkURL?.value.absoluteString, "https://artwork.invalid/original.png")
      XCTAssertEqual(track.isLiveStream, true)
      let expected: [String: Any] = [
        "url": "https://audio.invalid/track.mp3", "title": "Updated title", "artist": "Artist",
        "date": "2026-11-19", "album": "Album", "genre": "Spoken", "description": "Description",
        "duration": 120.0, "artwork": "https://artwork.invalid/original.png", "isLiveStream": true,
        "elapsedTime": 15.0,
      ]
      XCTAssertTrue(NSDictionary(dictionary: track.toObject()).isEqual(to: expected))
    }

    func testTrackExplicitNullMetadataClearsValuesAndSurvivesPartialUpdates() throws {
      let track = try XCTUnwrap(
        Track(dictionary: [
          "url": "https://audio.invalid/track.mp3", "title": "Title", "artist": "Artist",
          "date": "2026-11-19", "album": "Album", "genre": "Spoken", "description": "Description",
          "duration": 120.0, "artwork": "https://artwork.invalid/original.png",
          "isLiveStream": true,
        ]))
      let cleared: [String: Any] = [
        "title": NSNull(), "artist": NSNull(), "date": NSNull(), "album": NSNull(),
        "genre": NSNull(),
        "description": NSNull(), "duration": NSNull(), "artwork": NSNull(),
        "isLiveStream": NSNull(),
      ]

      track.updateMetadata(dictionary: cleared)
      track.updateMetadata(dictionary: ["elapsedTime": 15.0])

      XCTAssertNil(track.title)
      XCTAssertNil(track.artist)
      XCTAssertNil(track.date)
      XCTAssertNil(track.album)
      XCTAssertNil(track.genre)
      XCTAssertNil(track.desc)
      XCTAssertNil(track.duration)
      XCTAssertNil(track.artworkURL)
      XCTAssertNil(track.isLiveStream)
      for key in cleared.keys {
        XCTAssertTrue(track.toObject()[key] is NSNull, "Expected a serialized null for \(key)")
      }
      XCTAssertEqual(track.toObject()["elapsedTime"] as? Double, 15)
    }

    func testInvalidDownloadedImageKeepsExistingArtwork() throws {
      let controller = MetadataNowPlayingController()
      let player = AudioPlayer(nowPlayingInfoController: controller)
      player.loadArtwork { $0(image(width: 1)) }
      drainMainQueue()
      let (session, started) = makeSession(expectedRequests: 1)
      Metadata.update(
        for: player, with: ["artwork": "https://artwork.invalid/invalid.png"], urlSession: session)
      wait(for: [started], timeout: 5)

      try request(path: "/invalid.png").finish(data: Data("invalid".utf8))
      try finishSession()

      XCTAssertEqual(artworkWidth(controller), 1)
    }
  }
#endif
