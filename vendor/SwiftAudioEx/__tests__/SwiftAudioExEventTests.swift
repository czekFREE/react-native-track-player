#if os(iOS)
  import Foundation
  import XCTest

  private final class EventReleaseCleanup {
    private let cleanup: () -> Void

    init(cleanup: @escaping () -> Void) {
      self.cleanup = cleanup
    }

    deinit { cleanup() }
  }

  final class SwiftAudioExEventTests: XCTestCase {
    private func expectReleasedCallbackCanRemoveAnotherListener(pruneReleasedOwner: Bool) {
      let event = AudioPlayer.Event<Int>()
      var listener: NSObject? = NSObject()
      let otherListener = NSObject()
      let cleanedUp = expectation(description: "Released closure can remove another listener")
      let operationFinished = expectation(description: "The listener operation returns")
      var cleanup: EventReleaseCleanup? = EventReleaseCleanup {
        event.removeListener(otherListener)
        cleanedUp.fulfill()
      }
      if let listener = listener {
        event.addListener(listener, onMainQueue: true) { [cleanup] _ in
          withExtendedLifetime(cleanup) {}
        }
      }
      event.addListener(otherListener, onMainQueue: true) { _ in }
      cleanup = nil

      if pruneReleasedOwner {
        listener = nil
        DispatchQueue.global().async {
          event.emit(data: 1)
          operationFinished.fulfill()
        }
      } else if let listener = listener {
        DispatchQueue.global().async {
          event.removeListener(listener)
          operationFinished.fulfill()
        }
      }

      wait(for: [cleanedUp, operationFinished], timeout: 3)
    }

    func testRemovingListenerReleasesItsClosureOutsideTheListenerLock() {
      expectReleasedCallbackCanRemoveAnotherListener(pruneReleasedOwner: false)
    }

    func testPruningReleasedOwnerReleasesItsClosureOutsideTheListenerLock() {
      expectReleasedCallbackCanRemoveAnotherListener(pruneReleasedOwner: true)
    }

    func testDefaultListenersKeepAsynchronousOrderedEventHistory() {
      let event = AudioPlayer.Event<Int>()
      let received = expectation(description: "Both default events arrive off the emitter's thread")
      received.expectedFulfillmentCount = 2
      var values: [Int] = []
      XCTAssertTrue(Thread.isMainThread)
      event.addListener(self) { value in
        XCTAssertFalse(Thread.isMainThread)
        values.append(value)
        received.fulfill()
      }

      event.emit(data: 1)
      event.emit(data: 2)

      wait(for: [received], timeout: 3)
      XCTAssertEqual(values, [1, 2])
    }

    func testMainQueueListenersReceiveMainEmissionsBeforeTheNextOperation() {
      let event = AudioPlayer.Event<Int>()
      var values: [Int] = []
      event.addListener(self, onMainQueue: true) { value in
        XCTAssertTrue(Thread.isMainThread)
        values.append(value)
      }

      event.emit(data: 1)
      XCTAssertEqual(values, [1])
      event.emit(data: 2)
      XCTAssertEqual(values, [1, 2])
    }

    func testMainQueueListenersReceiveBackgroundEmissionsOnMain() {
      let event = AudioPlayer.Event<Int>()
      let received = expectation(description: "Background emission reaches the main queue")
      event.addListener(self, onMainQueue: true) { value in
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(value, 7)
        received.fulfill()
      }

      DispatchQueue.global().async { event.emit(data: 7) }

      wait(for: [received], timeout: 3)
    }

    func testMainQueueEmissionDeliversEarlierBackgroundEmissionFirst() {
      let event = AudioPlayer.Event<Int>()
      let backgroundEmissionFinished = DispatchSemaphore(value: 0)
      let received = expectation(description: "Both events arrive once in emission order")
      received.expectedFulfillmentCount = 2
      var values: [Int] = []
      XCTAssertTrue(Thread.isMainThread)
      event.addListener(self, onMainQueue: true) { value in
        XCTAssertTrue(Thread.isMainThread)
        values.append(value)
        received.fulfill()
      }

      DispatchQueue.global().async {
        event.emit(data: 1)
        backgroundEmissionFinished.signal()
      }
      XCTAssertEqual(backgroundEmissionFinished.wait(timeout: .now() + 3), .success)

      event.emit(data: 2)
      XCTAssertEqual(values, [1, 2])

      let mainQueueDrained = expectation(description: "The scheduled background delivery finishes")
      DispatchQueue.main.async { mainQueueDrained.fulfill() }
      wait(for: [received, mainQueueDrained], timeout: 3)
      XCTAssertEqual(values, [1, 2])
    }

    func testReentrantMainQueueEmissionReachesEveryListenerInOrder() {
      let event = AudioPlayer.Event<Int>()
      let otherListener = NSObject()
      var values: [String] = []
      event.addListener(self, onMainQueue: true) { [weak event] value in
        values.append("first-\(value)")
        if value == 1 { event?.emit(data: 2) }
      }
      event.addListener(otherListener, onMainQueue: true) { value in
        values.append("second-\(value)")
      }

      event.emit(data: 1)

      XCTAssertEqual(values, ["first-1", "second-1", "first-2", "second-2"])
    }

    func testMainQueueCallbackCanReplaceItsListenerAndEmitAgain() {
      let event = AudioPlayer.Event<Int>()
      let firstListener = NSObject()
      let secondListener = NSObject()
      var values: [String] = []
      event.addListener(firstListener, onMainQueue: true) { [weak event] value in
        values.append("first-\(value)")
        event?.removeListener(firstListener)
        event?.addListener(secondListener, onMainQueue: true) { value in
          values.append("second-\(value)")
        }
        event?.emit(data: 2)
      }

      event.emit(data: 1)
      event.emit(data: 3)

      XCTAssertEqual(values, ["first-1", "second-2", "second-3"])
    }

    func testMainQueueListenerRemovalPreventsLaterDelivery() {
      let event = AudioPlayer.Event<Int>()
      var values: [Int] = []
      event.addListener(self, onMainQueue: true) { values.append($0) }

      event.emit(data: 1)
      event.removeListener(self)
      event.emit(data: 2)

      XCTAssertEqual(values, [1])
    }

    func testMainQueueListenerDoesNotRetainItsOwner() {
      let event = AudioPlayer.Event<Int>()
      var listener: NSObject? = NSObject()
      weak var weakListener = listener
      var values: [Int] = []
      if let listener = listener {
        event.addListener(listener, onMainQueue: true) { values.append($0) }
      }
      listener = nil

      event.emit(data: 1)

      XCTAssertNil(weakListener)
      XCTAssertEqual(values, [])
    }
  }
#endif
