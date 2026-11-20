import Foundation
import XCTest

private final class QueueDelegateSpy: QueueManagerDelegate {
  var currentItemChanged: () -> Void = {}
  var skippedToSameCurrentItem: () -> Void = {}

  func onCurrentItemChanged() { currentItemChanged() }
  func onSkippedToSameCurrentItem() { skippedToSameCurrentItem() }
}

final class SwiftAudioExQueueTests: XCTestCase {
  func testEmptyQueueHasNoCurrentOrAdjacentItems() {
    let queue = QueueManager<String>()

    XCTAssertEqual(queue.currentIndex, -1)
    XCTAssertNil(queue.current)
    XCTAssertEqual(queue.items, [])
    XCTAssertEqual(queue.previousItems, [])
    XCTAssertEqual(queue.nextItems, [])
    XCTAssertNil(queue.next(wrap: true))
    XCTAssertNil(queue.previous(wrap: true))
    queue.removePreviousItems()
    queue.removeUpcomingItems()
    queue.clearQueue()
    XCTAssertEqual(queue.items, [])
  }

  func testAddingToAnEmptyQueueSelectsTheFirstItemWithoutADelegate() {
    let queue = QueueManager<String>()

    queue.add(["a", "b"])

    XCTAssertEqual(queue.current, "a")
    XCTAssertEqual(queue.currentIndex, 0)
    XCTAssertEqual(queue.next(), "b")
  }

  func testMovingItemsPreservesActiveItemAcrossEverySourceAndDestination() throws {
    let original = ["a", "b", "c", "d"]
    for activeIndex in original.indices {
      for sourceIndex in original.indices {
        for destinationIndex in [0, 1, 2, 3, 4, 100, Int.max] {
          let queue = QueueManager<String>()
          queue.add(original)
          try queue.jump(to: activeIndex)
          let delegate = QueueDelegateSpy()
          var notifications = 0
          delegate.currentItemChanged = { notifications += 1 }
          delegate.skippedToSameCurrentItem = { notifications += 1 }
          queue.delegate = delegate
          var expected = original
          let movedItem = expected.remove(at: sourceIndex)
          expected.insert(movedItem, at: min(destinationIndex, expected.count))

          try queue.moveItem(fromIndex: sourceIndex, toIndex: destinationIndex)

          XCTAssertEqual(queue.items, expected)
          XCTAssertEqual(queue.current, original[activeIndex])
          XCTAssertEqual(queue.currentIndex, expected.firstIndex(of: original[activeIndex]))
          XCTAssertEqual(queue.previousItems, Array(expected.prefix(queue.currentIndex)))
          XCTAssertEqual(queue.nextItems, Array(expected.dropFirst(queue.currentIndex + 1)))
          XCTAssertEqual(notifications, 0)
        }
      }
    }
  }

  func testMovingOnlyItemDoesNotAnnounceAnActiveItemChange() throws {
    let queue = QueueManager<String>()
    queue.add("active")
    let delegate = QueueDelegateSpy()
    var currentItemNotifications = 0
    delegate.currentItemChanged = { currentItemNotifications += 1 }
    queue.delegate = delegate

    try queue.moveItem(fromIndex: 0, toIndex: 10)

    XCTAssertEqual(queue.items, ["active"])
    XCTAssertEqual(queue.current, "active")
    XCTAssertEqual(queue.currentIndex, 0)
    XCTAssertEqual(currentItemNotifications, 0)
  }

  func testInsertingBeforeOnlyActiveItemPreservesItsIdentity() throws {
    let queue = QueueManager<String>()
    queue.add("active")
    try queue.add(["first", "second"], at: 0)

    XCTAssertEqual(queue.items, ["first", "second", "active"])
    XCTAssertEqual(queue.currentIndex, 2)
    XCTAssertEqual(queue.current, "active")
  }

  func testAddingFirstItemsSelectsTheFirstItemBeforeNotifyingOutsideTheLock() throws {
    let addOperations: [(QueueManager<String>) throws -> Void] = [
      { queue in queue.add("a") },
      { queue in queue.add(["a", "b"]) },
      { queue in try queue.add(["a", "b"], at: 0) },
      { queue in queue.replaceCurrentItem(with: "a") },
    ]
    for add in addOperations {
      let queue = QueueManager<String>()
      let delegate = QueueDelegateSpy()
      var activeItems: [String?] = []
      delegate.currentItemChanged = {
        self.expectQueueReadableOnAnotherThread(queue)
        activeItems.append(queue.current)
      }
      queue.delegate = delegate

      try add(queue)

      XCTAssertEqual(activeItems, ["a"])
      XCTAssertEqual(queue.current, "a")
      XCTAssertEqual(queue.currentIndex, 0)
    }
  }

  func testNavigationNotifiesAfterUnlockingAndKeepsBoundaryBehavior() {
    let queue = QueueManager<String>()
    queue.add(["a", "b", "c"])
    let delegate = QueueDelegateSpy()
    var activeItems: [String?] = []
    delegate.currentItemChanged = {
      self.expectQueueReadableOnAnotherThread(queue)
      activeItems.append(queue.current)
    }
    queue.delegate = delegate

    XCTAssertEqual(queue.previous(), "a")
    XCTAssertEqual(queue.next(), "b")
    XCTAssertEqual(queue.next(), "c")
    XCTAssertEqual(queue.next(), "c")
    XCTAssertEqual(queue.next(wrap: true), "a")
    XCTAssertEqual(queue.previous(wrap: true), "c")
    XCTAssertEqual(queue.previous(), "b")

    XCTAssertEqual(activeItems, ["b", "c", "a", "c", "b"])
  }

  func testWrappingSingleItemNotifiesAfterUnlocking() {
    let queue = QueueManager<String>()
    queue.add("a")
    let delegate = QueueDelegateSpy()
    var skippedCount = 0
    delegate.skippedToSameCurrentItem = {
      self.expectQueueReadableOnAnotherThread(queue)
      skippedCount += 1
    }
    queue.delegate = delegate

    XCTAssertEqual(queue.next(), "a")
    XCTAssertEqual(queue.previous(), "a")
    XCTAssertEqual(skippedCount, 0)
    XCTAssertEqual(queue.next(wrap: true), "a")
    XCTAssertEqual(queue.previous(wrap: true), "a")
    XCTAssertEqual(skippedCount, 2)
  }

  func testDelegateCanMutateQueueBeforeNavigationReturns() {
    let queue = QueueManager<String>()
    queue.add(["a", "b", "c"])
    let delegate = QueueDelegateSpy()
    var notifications = 0
    delegate.currentItemChanged = {
      notifications += 1
      queue.removeUpcomingItems()
    }
    queue.delegate = delegate

    XCTAssertEqual(queue.next(), "b")

    XCTAssertEqual(queue.items, ["a", "b"])
    XCTAssertEqual(queue.current, "b")
    XCTAssertEqual(notifications, 1)
  }

  func testNavigationReturnsTheCurrentItemAfterADelegateClearsTheQueue() {
    let queue = QueueManager<String>()
    queue.add(["a", "b"])
    let delegate = QueueDelegateSpy()
    delegate.currentItemChanged = { queue.clearQueue() }
    queue.delegate = delegate

    XCTAssertNil(queue.next())

    XCTAssertEqual(queue.items, [])
    XCTAssertEqual(queue.currentIndex, -1)
  }

  func testRemovalAndTrimmingPreserveTheCurrentItemUntilItIsRemoved() throws {
    let queue = QueueManager<String>()
    queue.add(["a", "b", "c", "d", "e"])
    try queue.jump(to: 2)
    let delegate = QueueDelegateSpy()
    var currentItems: [String?] = []
    delegate.currentItemChanged = {
      self.expectQueueReadableOnAnotherThread(queue)
      currentItems.append(queue.current)
    }
    queue.delegate = delegate

    XCTAssertEqual(try queue.removeItem(at: 0), "a")
    XCTAssertEqual(queue.currentIndex, 1)
    XCTAssertEqual(queue.current, "c")
    queue.removePreviousItems()
    queue.removeUpcomingItems()
    XCTAssertEqual(queue.items, ["c"])
    XCTAssertEqual(queue.currentIndex, 0)
    XCTAssertEqual(currentItems.count, 0)
    XCTAssertEqual(try queue.removeItem(at: 0), "c")
    XCTAssertEqual(queue.currentIndex, -1)
    XCTAssertNil(queue.current)
    XCTAssertEqual(currentItems.count, 1)
    XCTAssertNil(currentItems[0])
  }

  func testReplaceAndClearNotifyAfterUnlocking() {
    let queue = QueueManager<String>()
    queue.add("a")
    let delegate = QueueDelegateSpy()
    var currentItems: [String?] = []
    delegate.currentItemChanged = {
      self.expectQueueReadableOnAnotherThread(queue)
      currentItems.append(queue.current)
    }
    queue.delegate = delegate

    queue.replaceCurrentItem(with: "b")
    queue.clearQueue()
    queue.clearQueue()

    XCTAssertEqual(currentItems.count, 2)
    XCTAssertEqual(currentItems[0], "b")
    XCTAssertNil(currentItems[1])
  }

  func testReplacingTheActiveItemPreservesTheRestOfTheQueue() throws {
    let queue = QueueManager<String>()
    queue.add(["a", "b", "c"])
    try queue.jump(to: 1)
    let delegate = QueueDelegateSpy()
    var currentItems: [String?] = []
    delegate.currentItemChanged = { currentItems.append(queue.current) }
    queue.delegate = delegate

    queue.replaceCurrentItem(with: "replacement")

    XCTAssertEqual(queue.items, ["a", "replacement", "c"])
    XCTAssertEqual(queue.currentIndex, 1)
    XCTAssertEqual(currentItems, ["replacement"])
  }

  func testClearingQueueFromFirstItemCallbackDoesNotRestoreTheRemovedItem() {
    let queue = QueueManager<String>()
    let delegate = QueueDelegateSpy()
    var activeItems: [String?] = []
    delegate.currentItemChanged = {
      let current = queue.current
      activeItems.append(current)
      if current == "replacement" { queue.clearQueue() }
    }
    queue.delegate = delegate

    queue.replaceCurrentItem(with: "replacement")

    XCTAssertEqual(queue.items, [])
    XCTAssertEqual(queue.currentIndex, -1)
    XCTAssertNil(queue.current)
    XCTAssertEqual(activeItems, ["replacement", nil])
  }

  func testAnotherThreadCanClearTheQueueDuringFirstItemNotification() {
    let queue = QueueManager<String>()
    let delegate = QueueDelegateSpy()
    delegate.currentItemChanged = {
      guard queue.current == "a" else { return }
      let cleared = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        queue.clearQueue()
        cleared.signal()
      }
      XCTAssertEqual(cleared.wait(timeout: .now() + 1), .success)
    }
    queue.delegate = delegate

    queue.add("a")

    XCTAssertEqual(queue.items, [])
    XCTAssertEqual(queue.currentIndex, -1)
    XCTAssertNil(queue.current)
  }

  func testInvalidOperationsLeaveQueueUnchanged() throws {
    let queue = QueueManager<String>()
    queue.add(["a", "b"])
    try queue.jump(to: 1)
    for operation in invalidOperations(queue) {
      XCTAssertThrowsError(try operation()) { error in
        guard case AudioPlayerError.QueueError.invalidIndex = error else {
          return XCTFail("Expected invalidIndex, received \(error)")
        }
      }
      XCTAssertEqual(queue.items, ["a", "b"])
      XCTAssertEqual(queue.currentIndex, 1)
      XCTAssertEqual(queue.current, "b")
    }
  }

  func testEmptyOperationsReturnQueueEmptyError() {
    let queue = QueueManager<String>()
    let operations: [() throws -> Void] = [
      { _ = try queue.jump(to: 0) },
      { _ = try queue.removeItem(at: 0) },
      { try queue.moveItem(fromIndex: 0, toIndex: 0) },
    ]
    for operation in operations {
      XCTAssertThrowsError(try operation()) { error in
        guard case AudioPlayerError.QueueError.empty = error else {
          return XCTFail("Expected empty, received \(error)")
        }
      }
    }
  }

  #if os(macOS)
    func testInvalidOperationsReleaseQueueForOtherThreads() throws {
      let childEnvironmentKey = "YRT_QUEUE_LOCK_PROBE"
      if ProcessInfo.processInfo.environment[childEnvironmentKey] == "1" {
        let queue = QueueManager<String>()
        queue.add(["a", "b"])
        try queue.jump(to: 1)
        for operation in invalidOperations(queue) {
          XCTAssertThrowsError(try operation())
          let completed = DispatchSemaphore(value: 0)
          DispatchQueue.global().async {
            _ = queue.current
            completed.signal()
          }
          XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        }
        return
      }

      let child = Process()
      child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      child.arguments = [
        "--sdk", "macosx", "xctest", "-XCTest",
        "SwiftAudioExQueueTests/testInvalidOperationsReleaseQueueForOtherThreads",
        Bundle(for: SwiftAudioExQueueTests.self).bundleURL.path,
      ]
      var environment = ProcessInfo.processInfo.environment
      environment[childEnvironmentKey] = "1"
      child.environment = environment
      let exited = DispatchSemaphore(value: 0)
      child.terminationHandler = { _ in exited.signal() }

      try child.run()
      if exited.wait(timeout: .now() + 30) == .timedOut {
        child.terminate()
        _ = exited.wait(timeout: .now() + 2)
        return XCTFail("Queue access did not complete after an invalid operation")
      }

      XCTAssertEqual(child.terminationStatus, 0)
    }
  #endif

  private func invalidOperations(_ queue: QueueManager<String>) -> [() throws -> Void] {
    [
      { _ = try queue.jump(to: -1) },
      { _ = try queue.jump(to: 2) },
      { _ = try queue.removeItem(at: -1) },
      { _ = try queue.removeItem(at: 2) },
      { try queue.moveItem(fromIndex: -1, toIndex: 0) },
      { try queue.moveItem(fromIndex: 2, toIndex: 0) },
      { try queue.moveItem(fromIndex: 0, toIndex: -1) },
      { try queue.add(["c"], at: -1) },
      { try queue.add(["c"], at: 3) },
    ]
  }

  private func expectQueueReadableOnAnotherThread(
    _ queue: QueueManager<String>, file: StaticString = #filePath, line: UInt = #line
  ) {
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = queue.current
      _ = queue.items
      _ = queue.currentIndex
      completed.signal()
    }
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success, file: file, line: line)
  }
}
