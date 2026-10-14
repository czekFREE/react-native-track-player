import Foundation
import XCTest

final class AudioSessionPlaybackActivationTests: XCTestCase {
    private let failure = NSError(
        domain: "AudioSessionTest", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Session is busy"])

    func testEveryExplicitPlayConfiguresBeforeActivatingEvenWhenAlreadyActive() throws {
        var operations: [String] = []
        let session = AudioSessionPlaybackActivation(
            activateSession: { operations.append("activate") }, deactivateSession: {})
        try session.activate(userInitiated: true) { operations.append("configure") }
        try session.activate(userInitiated: true) { operations.append("configure") }
        XCTAssertEqual(operations, ["configure", "activate", "configure", "activate"])
        XCTAssertTrue(session.isActive)
    }

    func testRepeatedActivationFailuresCanRecoverOnLaterExplicitPlay() throws {
        var attempts = 0
        let failure = failure
        let session = AudioSessionPlaybackActivation(
            activateSession: {
                attempts += 1
                if attempts < 3 { throw failure }
            }, deactivateSession: {})
        for _ in 0..<2 {
            XCTAssertThrowsError(try session.activate(userInitiated: true, configureSession: {})) {
                error in
                XCTAssertEqual(
                    (error as? AudioSessionPlaybackError)?.code, "audio_session_activation_failed")
                XCTAssertEqual(error.localizedDescription, "Session is busy")
            }
            XCTAssertFalse(session.isActive)
        }
        try session.activate(userInitiated: true, configureSession: {})
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(session.isActive)
    }

    func testConfigurationFailurePreventsActivationAndCanBeRetried() throws {
        var attempts = 0
        let session = AudioSessionPlaybackActivation(
            activateSession: { attempts += 1 }, deactivateSession: {})
        XCTAssertThrowsError(
            try session.activate(userInitiated: true, configureSession: { throw failure })
        ) { error in
            XCTAssertEqual(
                (error as? AudioSessionPlaybackError)?.code, "audio_session_configuration_failed")
        }
        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(session.isActive)
        try session.activate(userInitiated: true, configureSession: {})
        XCTAssertEqual(attempts, 1)
    }

    func testResetNeverActivatesAndRejectsAutomaticResumeUntilExplicitPlaySucceeds() throws {
        var operations: [String] = []
        let session = AudioSessionPlaybackActivation(
            activateSession: { operations.append("activate") }, deactivateSession: {})
        session.mediaServicesWereReset()
        XCTAssertTrue(session.requiresExplicitPlay)
        XCTAssertThrowsError(
            try session.activate(userInitiated: false) { operations.append("configure") }
        ) { error in
            XCTAssertEqual(
                (error as? AudioSessionPlaybackError)?.code,
                "ios_audio_session_requires_explicit_play")
        }
        XCTAssertEqual(operations, [])
        try session.activate(userInitiated: true) { operations.append("configure") }
        XCTAssertEqual(operations, ["configure", "activate"])
        XCTAssertFalse(session.requiresExplicitPlay)
    }

    func testFailedExplicitPlayKeepsResetGateClosed() {
        let failure = failure
        let session = AudioSessionPlaybackActivation(
            activateSession: { throw failure }, deactivateSession: {})
        session.mediaServicesWereReset()
        XCTAssertThrowsError(try session.activate(userInitiated: true, configureSession: {}))
        XCTAssertTrue(session.requiresExplicitPlay)
        XCTAssertThrowsError(try session.activate(userInitiated: false, configureSession: {})) {
            error in
            XCTAssertEqual(
                (error as? AudioSessionPlaybackError)?.code,
                "ios_audio_session_requires_explicit_play")
        }
    }

    func testInterruptionAndDeactivationDoNotClearResetGate() throws {
        let session = AudioSessionPlaybackActivation(activateSession: {}, deactivateSession: {})
        session.mediaServicesWereReset()
        session.invalidateForInterruption()
        try session.deactivate()
        XCTAssertTrue(session.requiresExplicitPlay)
        XCTAssertFalse(session.isActive)
    }

    func testRepeatedResetClosesGateAfterEarlierRecovery() throws {
        let session = AudioSessionPlaybackActivation(activateSession: {}, deactivateSession: {})
        session.mediaServicesWereReset()
        try session.activate(userInitiated: true, configureSession: {})
        session.mediaServicesWereReset()
        XCTAssertThrowsError(try session.activate(userInitiated: false, configureSession: {}))
        XCTAssertTrue(session.requiresExplicitPlay)
    }

    func testDeactivationFailurePreservesError() {
        let failure = failure
        let session = AudioSessionPlaybackActivation(
            activateSession: {}, deactivateSession: { throw failure })
        XCTAssertThrowsError(try session.deactivate()) { error in
            XCTAssertEqual(
                (error as? AudioSessionPlaybackError)?.code, "audio_session_deactivation_failed")
            XCTAssertEqual(error.localizedDescription, "Session is busy")
        }
    }

    func testPlayCapturedBeforeResetCannotAdmitPlaybackAfterReset() throws {
        let session = AudioSessionPlaybackActivation(activateSession: {}, deactivateSession: {})
        let oldRevision = session.captureResetRevision()
        session.mediaServicesWereReset()
        XCTAssertThrowsError(try session.requireCurrentResetRevision(oldRevision)) { error in
            XCTAssertEqual(
                (error as? AudioSessionPlaybackError)?.code,
                "ios_audio_session_requires_explicit_play")
        }
        try session.requireCurrentResetRevision(session.captureResetRevision())
    }

    func testRevisionCaptureFromBackgroundObservesRepeatedReset() {
        let session = AudioSessionPlaybackActivation(activateSession: {}, deactivateSession: {})
        session.mediaServicesWereReset()
        let captured = expectation(description: "Background caller captured revision")
        DispatchQueue.global().async {
            XCTAssertEqual(session.captureResetRevision(), 1)
            captured.fulfill()
        }
        wait(for: [captured], timeout: 1)
        session.mediaServicesWereReset()
        XCTAssertEqual(session.captureResetRevision(), 2)
        XCTAssertThrowsError(try session.requireCurrentResetRevision(1))
    }
}
