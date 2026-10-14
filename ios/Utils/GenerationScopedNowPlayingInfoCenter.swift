import Foundation
import MediaPlayer
import SwiftAudioEx

final class GenerationScopedNowPlayingInfoCenter: NowPlayingInfoCenter {
    private let generation: PlaybackOwnerGeneration
    private var center: NowPlayingInfoCenter

    init(
        generation: PlaybackOwnerGeneration,
        center: NowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    ) {
        self.generation = generation
        self.center = center
    }

    var nowPlayingInfo: [String: Any]? {
        get { center.nowPlayingInfo }
        set {
            generation.performOnMainIfCurrent { [weak self] in
                self?.center.nowPlayingInfo = newValue
            }
        }
    }
}
