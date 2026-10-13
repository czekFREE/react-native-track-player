import Foundation
import SwiftAudioEx
import XCTest

final class PlaybackErrorKeyValuesTests: XCTestCase {
    func testKnownFailuresExposeTheirCodeAndMessage() {
        let failures: [(AudioPlayerError.PlaybackError, String, String)] = [
            (.failedToLoadKeyValue, "ios_failed_to_load_resource", "Failed to load resource"),
            (.invalidSourceUrl("invalid"), "ios_invalid_source_url", "The source url was invalid"),
            (
                .notConnectedToInternet,
                "ios_not_connected_to_internet",
                "A network resource was requested, but an internet connection has not been established and can’t be established automatically."
            ),
            (.playbackFailed, "ios_playback_failed", "Playback of the track failed"),
            (.itemWasUnplayable, "ios_track_unplayable", "The track could not be played"),
        ]

        for (error, code, message) in failures {
            XCTAssertEqual(
                getPlaybackErrorKeyValues(error: error), ["code": code, "message": message])
        }
    }

    func testUnknownNativeFailurePreservesItsDescription() {
        let error = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11819,
            userInfo: [NSLocalizedDescriptionKey: "The media services were reset"]
        )

        XCTAssertEqual(
            getPlaybackErrorKeyValues(error: error),
            ["code": "ios_playback_error", "message": "The media services were reset"]
        )
    }

    func testMissingErrorStillHasAUsablePayload() {
        XCTAssertEqual(
            getPlaybackErrorKeyValues(error: nil),
            ["code": "ios_playback_error", "message": "A playback error occurred"]
        )
    }

}
