import Foundation
import SwiftAudioEx

func getPlaybackErrorKeyValues(error: Error?) -> [String: String] {
    switch error as? AudioPlayerError.PlaybackError {
    case .failedToLoadKeyValue:
        return ["message": "Failed to load resource", "code": "ios_failed_to_load_resource"]
    case .invalidSourceUrl:
        return ["message": "The source url was invalid", "code": "ios_invalid_source_url"]
    case .notConnectedToInternet:
        return [
            "message":
                "A network resource was requested, but an internet connection has not been established and can’t be established automatically.",
            "code": "ios_not_connected_to_internet",
        ]
    case .playbackFailed:
        return ["message": "Playback of the track failed", "code": "ios_playback_failed"]
    case .itemWasUnplayable:
        return ["message": "The track could not be played", "code": "ios_track_unplayable"]
    case nil:
        return [
            "message": error?.localizedDescription ?? "A playback error occurred",
            "code": "ios_playback_error",
        ]
    }
}
