import Foundation
import MediaPlayer
import SwiftAudioEx

struct NativePlayerSnapshot {
    let items: [AudioItem]
    let currentIndex: Int
    let position: Double
    let rate: Float
    let volume: Float
    let isMuted: Bool
    let bufferDuration: TimeInterval
    let automaticallyWaitsToMinimizeStalling: Bool
    let timeEventFrequency: TimeEventFrequency
    let audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm
    let repeatMode: SwiftAudioEx.RepeatMode
    let automaticallyUpdateNowPlayingInfo: Bool
    let remoteCommands: [RemoteCommand]
    let nowPlayingInfo: [String: Any]?

    init(player: QueuedAudioPlayer, position: Double) {
        items = player.items
        currentIndex = player.currentIndex
        self.position = position
        rate = player.rate
        volume = player.volume
        isMuted = player.isMuted
        bufferDuration = player.bufferDuration
        automaticallyWaitsToMinimizeStalling = player.automaticallyWaitsToMinimizeStalling
        timeEventFrequency = player.timeEventFrequency
        audioTimePitchAlgorithm = player.audioTimePitchAlgorithm
        repeatMode = player.repeatMode
        automaticallyUpdateNowPlayingInfo = player.automaticallyUpdateNowPlayingInfo
        remoteCommands = player.remoteCommands
        nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
    }

    func restore(to player: QueuedAudioPlayer) throws {
        player.playWhenReady = false
        player.bufferDuration = bufferDuration
        player.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
        player.timeEventFrequency = timeEventFrequency
        player.audioTimePitchAlgorithm = audioTimePitchAlgorithm
        player.automaticallyUpdateNowPlayingInfo = false
        player.rate = rate
        player.volume = volume
        player.isMuted = isMuted
        player.repeatMode = repeatMode
        player.remoteCommands = remoteCommands
        player.add(items: items, playWhenReady: false)
        if items.indices.contains(currentIndex) {
            try player.jumpToItem(atIndex: currentIndex, playWhenReady: false)
            if position.isFinite && position >= 0 { player.seek(to: position) }
        }
        player.automaticallyUpdateNowPlayingInfo = automaticallyUpdateNowPlayingInfo
        if automaticallyUpdateNowPlayingInfo { player.loadNowPlayingMetaValues() }
        if let nowPlayingInfo = nowPlayingInfo {
            player.nowPlayingInfoController.set(
                keyValues: nowPlayingInfo.map {
                    RestoredNowPlayingInfoValue(key: $0.key, value: $0.value)
                })
            player.nowPlayingInfoController.set(keyValues: [
                NowPlayingInfoProperty.elapsedPlaybackTime(position),
                NowPlayingInfoProperty.playbackRate(0),
            ])
        }
    }
}

private struct RestoredNowPlayingInfoValue: NowPlayingInfoKeyValue {
    let key: String
    let value: Any

    func getKey() -> String { key }
    func getValue() -> Any? { value }
}
