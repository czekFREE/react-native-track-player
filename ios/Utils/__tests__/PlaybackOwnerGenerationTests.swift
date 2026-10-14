import Foundation
import XCTest

final class PlaybackOwnerGenerationTests: XCTestCase {
    func testCurrentOwnerCanWriteAndRetiredOwnerCannot() {
        let generation = PlaybackOwnerGeneration()
        var values: [String] = []
        generation.performOnMainIfCurrent { values.append("current") }
        generation.invalidate()
        generation.performOnMainIfCurrent { values.append("retired") }
        XCTAssertEqual(values, ["current"])
    }

    func testQueuedCallbackChecksOwnershipAfterMainQueueDispatch() {
        let generation = PlaybackOwnerGeneration()
        var values: [String] = []
        let callbackEnqueued = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            generation.performOnMainIfCurrent { values.append("retired") }
            callbackEnqueued.signal()
        }
        XCTAssertEqual(callbackEnqueued.wait(timeout: .now() + 1), .success)
        generation.invalidate()
        let completion = expectation(description: "Main queue callback processed")
        DispatchQueue.main.async { completion.fulfill() }
        wait(for: [completion], timeout: 1)
        XCTAssertEqual(values, [])
    }

    func testNewOwnerRemainsIndependentOfRetiredGeneration() {
        let retired = PlaybackOwnerGeneration()
        let current = PlaybackOwnerGeneration()
        retired.invalidate()
        var values: [String] = []
        retired.performOnMainIfCurrent { values.append("retired") }
        current.performOnMainIfCurrent { values.append("current") }
        XCTAssertEqual(values, ["current"])
    }
}
