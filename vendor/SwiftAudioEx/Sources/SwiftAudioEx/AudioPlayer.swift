//
//  AudioPlayer.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 15/03/2018.
//

import Foundation
import MediaPlayer

public typealias AudioPlayerState = AVPlayerWrapperState

public class AudioPlayer: AVPlayerWrapperDelegate {
    /// The wrapper around the underlying AVPlayer
    let wrapper: AVPlayerWrapperProtocol = AVPlayerWrapper()

    public let nowPlayingInfoController: NowPlayingInfoControllerProtocol
    public let remoteCommandController: RemoteCommandController
    public let event = EventHolder()

    private(set) var currentItem: AudioItem?
    private(set) var playbackCommandRevision: UInt = 0
    private var playbackIntentRevision: UInt = 0
    private var playbackFailureRevision: UInt = 0
    private var sourceOperationRevision: UInt = 0
    private var artworkRequestRevision: UInt = 0
    private var artworkTask: URLSessionDataTask?

    /**
     Set this to false to disable automatic updating of now playing info for control center and lock screen.
     */
    public var automaticallyUpdateNowPlayingInfo: Bool = true

    /// Disable this when the host app handles output disconnection. Defaults to `true`.
    public var automaticallyPausesOnRouteLoss: Bool {
        get { wrapper.automaticallyPausesOnRouteLoss }
        set { wrapper.automaticallyPausesOnRouteLoss = newValue }
    }

    /// An optional, side-effect-free check before the player starts or resumes playback.
    public var playbackPermission: (() -> Bool)? {
        get { wrapper.playbackPermission }
        set { wrapper.playbackPermission = newValue }
    }

    /**
     Controls the time pitch algorithm applied to each item loaded into the player.
     If the loaded `AudioItem` conforms to `TimePitcher`-protocol this will be overriden.
     */
    public var audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm = AVAudioTimePitchAlgorithm.timeDomain

    /**
     Default remote commands to use for each playing item
     */
    public var remoteCommands: [RemoteCommand] = [] {
        didSet {
            if let item = currentItem {
                self.enableRemoteCommands(forItem: item)
            }
        }
    }

    internal func handlePlayWhenReady(_ playWhenReady: Bool?, action: () throws -> Void) rethrows {
        sourceOperationRevision &+= 1
        let sourceRevision = sourceOperationRevision
        if playWhenReady != nil {
            playbackIntentRevision &+= 1
            invalidatePendingReplay()
        }
        let revision = playbackIntentRevision
        if playWhenReady == false {
            wrapper.pause()
        }
        guard sourceOperationRevision == sourceRevision else { return }

        let failureRevision = playbackFailureRevision
        try action()

        if playWhenReady == true, playbackIntentRevision == revision,
            playbackError == nil || playbackFailureRevision == failureRevision
        {
            self.playWhenReady = true
        }
    }

    // MARK: - Getters from AVPlayerWrapper

    public var playbackError: AudioPlayerError.PlaybackError? {
        wrapper.playbackError
    }
    
    /**
     The elapsed playback time of the current item.
     */
    public var currentTime: Double {
        wrapper.currentTime
    }

    public var pendingSeekPosition: TimeInterval? {
        wrapper.pendingSeekPosition
    }

    public var recoveryPosition: TimeInterval? {
        wrapper.recoveryPosition
    }

    /**
     The duration of the current AudioItem.
     */
    public var duration: Double {
        wrapper.duration
    }

    /**
     The bufferedPosition of the current AudioItem.
     */
    public var bufferedPosition: Double {
        wrapper.bufferedPosition
    }

    /**
     The current state of the underlying `AudioPlayer`.
     */
    public var playerState: AudioPlayerState {
        wrapper.state
    }

    // MARK: - Setters for AVPlayerWrapper

    /**
     Whether the player should start playing automatically when the item is ready.
     */
    public var playWhenReady: Bool {
        get { wrapper.playWhenReady }
        set {
            playbackIntentRevision &+= 1
            invalidatePendingReplay()
            if newValue { wrapper.play() } else { wrapper.pause() }
        }
    }
    
    /**
     The amount of seconds to be buffered by the player. Default value is 0 seconds, this means the AVPlayer will choose an appropriate level of buffering. Setting `bufferDuration` to larger than zero automatically disables `automaticallyWaitsToMinimizeStalling`. Setting it back to zero automatically enables `automaticallyWaitsToMinimizeStalling`.

     [Read more from Apple Documentation](https://developer.apple.com/documentation/avfoundation/avplayeritem/1643630-preferredforwardbufferduration)
     */
    public var bufferDuration: TimeInterval {
        get { wrapper.bufferDuration }
        set {
            wrapper.bufferDuration = newValue
            wrapper.automaticallyWaitsToMinimizeStalling = wrapper.bufferDuration == 0
        }
    }

    /**
     Indicates whether the player should automatically delay playback in order to minimize stalling. Setting this to true will also set `bufferDuration` back to `0`.

     [Read more from Apple Documentation](https://developer.apple.com/documentation/avfoundation/avplayer/1643482-automaticallywaitstominimizestal)
     */
    public var automaticallyWaitsToMinimizeStalling: Bool {
        get { wrapper.automaticallyWaitsToMinimizeStalling }
        set {
            if (newValue) {
                wrapper.bufferDuration = 0
            }
            wrapper.automaticallyWaitsToMinimizeStalling = newValue
        }
    }
    
    /**
     Set this to decide how often the player should call the delegate with time progress events.
     */
    public var timeEventFrequency: TimeEventFrequency {
        get { wrapper.timeEventFrequency }
        set { wrapper.timeEventFrequency = newValue }
    }

    public var volume: Float {
        get { wrapper.volume }
        set { wrapper.volume = newValue }
    }

    public var isMuted: Bool {
        get { wrapper.isMuted }
        set { wrapper.isMuted = newValue }
    }

    public var rate: Float {
        get { wrapper.rate }
        set {
            wrapper.rate = newValue
            if (automaticallyUpdateNowPlayingInfo) {
                updateNowPlayingPlaybackValues()
            }
        }
    }

    // MARK: - Init

    /**
     Create a new AudioPlayer.

     - parameter infoCenter: The InfoCenter to update. Default is `MPNowPlayingInfoCenter.default()`.
     */
    public init(nowPlayingInfoController: NowPlayingInfoControllerProtocol = NowPlayingInfoController(),
                remoteCommandController: RemoteCommandController = RemoteCommandController()) {
        self.nowPlayingInfoController = nowPlayingInfoController
        self.remoteCommandController = remoteCommandController

        wrapper.delegate = self
        self.remoteCommandController.audioPlayer = self
    }

    deinit {
        artworkTask?.cancel()
    }

    // MARK: - Player Actions

    /**
     Load an AudioItem into the manager.

     - parameter item: The AudioItem to load. The info given in this item is the one used for the InfoCenter.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public func load(item: AudioItem, playWhenReady: Bool? = nil) {
        invalidatePendingReplay()
        invalidateArtworkRequest()
        handlePlayWhenReady(playWhenReady) {
            currentItem = item

            if (automaticallyUpdateNowPlayingInfo) {
                // Reset playback values without updating, because that will happen in
                // the loadNowPlayingMetaValues call straight after:
                nowPlayingInfoController.setWithoutUpdate(keyValues: [
                    MediaItemProperty.duration(nil),
                    NowPlayingInfoProperty.playbackRate(0),
                    NowPlayingInfoProperty.elapsedPlaybackTime(nil),
                    MediaItemProperty.artwork(nil)
                ])
                loadNowPlayingMetaValues(automaticallyUpdateOnly: true)
            }
            
            enableRemoteCommands(forItem: item)
            
            wrapper.load(
                from: item.getSourceUrl(),
                type: item.getSourceType(),
                playWhenReady: self.playWhenReady,
                initialTime: (item as? InitialTiming)?.getInitialTime(),
                options:(item as? AssetOptionsProviding)?.getAssetOptions()
            )
        }
    }

    /**
     Toggle playback status.
     */
    public func togglePlaying() {
        playbackIntentRevision &+= 1
        invalidatePendingReplay()
        wrapper.togglePlaying()
    }

    /**
     Start playback
     */
    public func play() {
        playbackIntentRevision &+= 1
        invalidatePendingReplay()
        wrapper.play()
    }

    /**
     Pause playback
     */
    public func pause() {
        playbackIntentRevision &+= 1
        invalidatePendingReplay()
        wrapper.pause()
    }

    /**
     Stop playback
     */
    public func stop() {
        sourceOperationRevision &+= 1
        playbackIntentRevision &+= 1
        invalidatePendingReplay()
        let wasActive = wrapper.playbackActive
        wrapper.stop()
        if (wasActive) {
            event.playbackEnd.emit(data: .playerStopped)
        }
    }

    /**
     Reload the current item.
     */
    public func reload(startFromCurrentTime: Bool) {
        sourceOperationRevision &+= 1
        invalidatePendingReplay()
        wrapper.reload(startFromCurrentTime: startFromCurrentTime)
    }
    
    /**
     Seek to a specific time in the item.
     */
    public func seek(to seconds: TimeInterval) {
        seek(to: seconds, completionHandler: nil)
    }

    public func seek(to seconds: TimeInterval, completionHandler: ((Bool) -> Void)?) {
        invalidatePendingReplay()
        wrapper.seek(to: seconds, completionHandler: completionHandler)
    }

    /**
     Seek by relative a time offset in the item.
     */
    public func seek(by offset: TimeInterval) {
        invalidatePendingReplay()
        wrapper.seek(by: offset)
    }
    
    // MARK: - Remote Command Center

    func enableRemoteCommands(_ commands: [RemoteCommand]) {
        remoteCommandController.enable(commands: commands)
    }

    func enableRemoteCommands(forItem item: AudioItem) {
        if let item = item as? RemoteCommandable {
            self.enableRemoteCommands(item.getCommands())
        }
        else {
            self.enableRemoteCommands(remoteCommands)
        }
    }

    /**
     Syncs the current remoteCommands with the iOS command center.
     Can be used to update item states - e.g. like, dislike and bookmark.
     */
    @available(*, deprecated, message: "Directly set .remoteCommands instead")
    public func syncRemoteCommandsWithCommandCenter() {
        self.enableRemoteCommands(remoteCommands)
    }

    // MARK: - NowPlayingInfo

    /**
     Loads NowPlayingInfo-meta values with the values found in the current `AudioItem`. Use this if a change to the `AudioItem` is made and you want to update the `NowPlayingInfoController`s values.

     Reloads:
     - Artist
     - Title
     - Album title
     - Album artwork
     */
    public func loadNowPlayingMetaValues() {
        loadNowPlayingMetaValues(automaticallyUpdateOnly: false)
    }

    private func loadNowPlayingMetaValues(automaticallyUpdateOnly: Bool) {
        guard let item = currentItem else { return }

        nowPlayingInfoController.set(keyValues: [
            MediaItemProperty.artist(item.getArtist()),
            MediaItemProperty.title(item.getTitle()),
            MediaItemProperty.albumTitle(item.getAlbumTitle()),
        ])
        loadArtwork(item.getArtwork, automaticallyUpdateOnly: automaticallyUpdateOnly)
    }

    /**
     Resyncs the playbackvalues of the currently playing `AudioItem`.

     Will resync:
     - Current time
     - Duration
     - Playback rate
     */
    func updateNowPlayingPlaybackValues() {
        nowPlayingInfoController.set(keyValues: [
            MediaItemProperty.duration(wrapper.duration),
            NowPlayingInfoProperty.playbackRate(
                wrapper.state == .playing && wrapper.playWhenReady ? Double(wrapper.rate) : 0
            ),
            NowPlayingInfoProperty.elapsedPlaybackTime(wrapper.currentTime)
        ])
    }

    public func clear() {
        sourceOperationRevision &+= 1
        playbackIntentRevision &+= 1
        invalidatePendingReplay()
        invalidateArtworkRequest()
        let playbackWasActive = wrapper.playbackActive
        currentItem = nil
        wrapper.unload()
        guard currentItem == nil else { return }
        nowPlayingInfoController.clear()
        if (playbackWasActive) {
            event.playbackEnd.emit(data: .cleared)
        }
    }

    // MARK: - Private

    func invalidatePendingReplay() {
        playbackCommandRevision &+= 1
    }

    private func setNowPlayingCurrentTime(seconds: Double) {
        nowPlayingInfoController.set(
            keyValue: NowPlayingInfoProperty.elapsedPlaybackTime(seconds)
        )
    }

    public func loadArtwork(
        _ loader: (@escaping (UIImage?) -> Void) -> Void,
        automaticallyUpdateOnly: Bool = false
    ) {
        invalidateArtworkRequest()
        let revision = artworkRequestRevision
        loader { [weak self] image in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.artworkRequestRevision == revision,
                      !automaticallyUpdateOnly || self.automaticallyUpdateNowPlayingInfo else { return }
                self.publishArtwork(image)
            }
        }
    }

    public func loadArtwork(from url: URL, urlSession: URLSession = .shared) {
        invalidateArtworkRequest()
        let revision = artworkRequestRevision
        let task = urlSession.dataTask(with: url) { [weak self] data, _, error in
            let image = error == nil ? data.flatMap { UIImage(data: $0) } : nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.artworkRequestRevision == revision else { return }
                self.artworkTask = nil
                if let image = image { self.publishArtwork(image) }
            }
        }
        artworkTask = task
        task.resume()
    }

    private func invalidateArtworkRequest() {
        artworkRequestRevision &+= 1
        artworkTask?.cancel()
        artworkTask = nil
    }

    private func publishArtwork(_ image: UIImage?) {
        let artwork = image.map { image in
            MPMediaItemArtwork(boundsSize: image.size, requestHandler: { _ in image })
        }
        nowPlayingInfoController.set(keyValue: MediaItemProperty.artwork(artwork))
    }

    func AVWrapper(didInstallItem item: AVPlayerItem) {
        if let currentItem = currentItem as? TimePitching {
            item.audioTimePitchAlgorithm = currentItem.getPitchAlgorithmType()
        } else {
            item.audioTimePitchAlgorithm = audioTimePitchAlgorithm
        }
    }

    // MARK: - AVPlayerWrapperDelegate

    func AVWrapper(didChangeState state: AVPlayerWrapperState) {
        if (automaticallyUpdateNowPlayingInfo) {
            updateNowPlayingPlaybackValues()
        }
        event.stateChange.emit(data: state)
    }

    func AVWrapper(secondsElapsed seconds: Double) {
        event.secondElapse.emit(data: seconds)
    }

    func AVWrapper(failedWithError error: Error?) {
        let failedRevision = wrapper.loadRevision
        playbackFailureRevision &+= 1
        event.fail.emit(data: error)
        guard wrapper.loadRevision == failedRevision else { return }
        event.playbackEnd.emit(data: .failed)
    }

    func AVWrapper(seekTo seconds: Double, didFinish: Bool) {
        if didFinish && automaticallyUpdateNowPlayingInfo {
            setNowPlayingCurrentTime(seconds: Double(seconds))
        }
        event.seek.emit(data: (seconds, didFinish))
    }

    func AVWrapper(didUpdateDuration duration: Double) {
        if (automaticallyUpdateNowPlayingInfo) {
            nowPlayingInfoController.set(keyValue: MediaItemProperty.duration(wrapper.duration))
        }
        event.updateDuration.emit(data: duration)
    }
    
    func AVWrapper(didReceiveCommonMetadata metadata: [AVMetadataItem]) {
        event.receiveCommonMetadata.emit(data: metadata)
    }
    
    func AVWrapper(didReceiveChapterMetadata metadata: [AVTimedMetadataGroup]) {
        event.receiveChapterMetadata.emit(data: metadata)
    }
    
    func AVWrapper(didReceiveTimedMetadata metadata: [AVTimedMetadataGroup]) {
        event.receiveTimedMetadata.emit(data: metadata)
    }

    func AVWrapper(didChangePlayWhenReady playWhenReady: Bool) {
        if (automaticallyUpdateNowPlayingInfo) {
            updateNowPlayingPlaybackValues()
        }
        event.playWhenReadyChange.emit(data: playWhenReady)
    }
    
    func AVWrapperItemDidPlayToEndTime() {
        let revision = playbackCommandRevision
        event.playbackEnd.emit(data: .playedUntilEnd)
        guard playbackCommandRevision == revision else { return }
        wrapper.state = .ended
    }

    func AVWrapperItemFailedToPlayToEndTime() {
        AVWrapper(failedWithError: AudioPlayerError.PlaybackError.playbackFailed)
    }

    func AVWrapperItemPlaybackStalled() {

    }
    
    func AVWrapperDidRecreateAVPlayer() {
        event.didRecreateAVPlayer.emit(data: ())
    }
}
