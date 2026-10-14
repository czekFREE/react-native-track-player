// TrackPlayer.swift
import Foundation
import MediaPlayer
import React
import SwiftAudioEx

private func logTrackPlayerDevelopment(_ message: @autoclosure () -> String) {
    #if DEBUG
        NSLog("%@", message())
    #endif
}

@objc(NativeTrackPlayerImpl)
public class NativeTrackPlayerImpl: NSObject, AudioSessionControllerDelegate {
    // Add property for the Objective-C bridge
    @objc public weak var delegate: NativeTrackPlayerImplDelegate? = nil

    // @objc
    // func constantsToExport() -> [String: Any]! {
    //   return ["someKey": "someValue"]
    // }

    // MARK: - Attributes

    private var hasInitialized = false
    private(set) var player: QueuedAudioPlayer
    private var ownerGeneration: PlaybackOwnerGeneration
    private let playerFactory: (PlaybackOwnerGeneration) -> QueuedAudioPlayer
    private let playbackSession: AudioSessionPlaybackActivation
    private let notificationCenter: NotificationCenter
    private let configureSession:
        (
            AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.RouteSharingPolicy,
            AVAudioSession.CategoryOptions
        ) throws -> Void
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var cachedPosition: Double = 0
    private var cachedPositionTrack: Track?
    private var pendingSeekPosition: Double?
    private var nowPlayingMetadata: [String: Any] = [:]
    private let audioSessionController = AudioSessionController.shared
    private var shouldEmitProgressEvent: Bool = false
    private var shouldResumePlaybackAfterInterruptionEnds: Bool = false
    private var forwardJumpInterval: NSNumber? = nil
    private var backwardJumpInterval: NSNumber? = nil
    private var sessionCategory: AVAudioSession.Category = .playback
    private var sessionCategoryMode: AVAudioSession.Mode = .default
    private var sessionCategoryPolicy: AVAudioSession.RouteSharingPolicy = .default
    private var sessionCategoryOptions: AVAudioSession.CategoryOptions = []

    // MARK: - Lifecycle Methods

    public override convenience init() {
        self.init(
            notificationCenter: .default,
            configureSession: { category, mode, policy, options in
                try AVAudioSession.sharedInstance().setCategory(
                    category, mode: mode, policy: policy, options: options)
            },
            activateSession: { try AudioSessionController.shared.activateSession() },
            deactivateSession: { try AudioSessionController.shared.deactivateSession() }
        )
    }

    init(
        playerFactory: @escaping (PlaybackOwnerGeneration) -> QueuedAudioPlayer =
            NativeTrackPlayerImpl
            .makePlayer,
        notificationCenter: NotificationCenter,
        configureSession:
            @escaping (
                AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.RouteSharingPolicy,
                AVAudioSession.CategoryOptions
            ) throws -> Void,
        activateSession: @escaping () throws -> Void,
        deactivateSession: @escaping () throws -> Void
    ) {
        let generation = PlaybackOwnerGeneration()
        ownerGeneration = generation
        player = playerFactory(generation)
        self.playerFactory = playerFactory
        self.notificationCenter = notificationCenter
        self.configureSession = configureSession
        playbackSession = AudioSessionPlaybackActivation(
            activateSession: activateSession, deactivateSession: deactivateSession)
        super.init()
        audioSessionController.delegate = self
        player.playWhenReady = false
        registerPlayerEvents(player: player, generation: generation)
        mediaServicesResetObserver = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.handleMediaServicesReset() }
    }

    private static func makePlayer(generation: PlaybackOwnerGeneration) -> QueuedAudioPlayer {
        QueuedAudioPlayer(
            nowPlayingInfoController: NowPlayingInfoController(
                infoCenter: GenerationScopedNowPlayingInfoCenter(generation: generation)
            ))
    }

    deinit {
        if let observer = mediaServicesResetObserver { notificationCenter.removeObserver(observer) }
        let generation = ownerGeneration
        let retiredPlayer = player
        DispatchQueue.main.async {
            generation.invalidate()
            retiredPlayer.remoteCommands = []
            retiredPlayer.syncRemoteCommandsWithCommandCenter()
            retiredPlayer.repeatMode = .off
            retiredPlayer.stop()
            retiredPlayer.clear()
        }
    }

    private func registerPlayerEvents(
        player: QueuedAudioPlayer, generation: PlaybackOwnerGeneration
    ) {
        player.event.receiveChapterMetadata.addListener(self) { [weak self] metadata in
            generation.performOnMainIfCurrent { [weak self] in
                self?.handleAudioPlayerChapterMetadataReceived(metadata: metadata)
            }
        }
        player.event.receiveTimedMetadata.addListener(self) { [weak self] metadata in
            generation.performOnMainIfCurrent { [weak self] in
                self?.handleAudioPlayerTimedMetadataReceived(metadata: metadata)
            }
        }
        player.event.receiveCommonMetadata.addListener(self) { [weak self] metadata in
            generation.performOnMainIfCurrent { [weak self] in
                self?.handleAudioPlayerCommonMetadataReceived(metadata: metadata)
            }
        }
        player.event.stateChange.addListener(self) { [weak self] state in
            generation.performOnMainIfCurrent { [weak self] in
                self?.handleAudioPlayerStateChange(state: state)
            }
        }
        player.event.fail.addListener(self) { [weak self] error in
            generation.performOnMainIfCurrent { [weak self] in
                self?.handleAudioPlayerFailed(error: error)
            }
        }
        player.event.currentItem.addListener(self) { [weak self] event in
            generation.performOnMainIfCurrent { [weak self] in
                self?.handleAudioPlayerCurrentItemChange(
                    item: event.item, index: event.index, lastItem: event.lastItem,
                    lastIndex: event.lastIndex, lastPosition: event.lastPosition)
            }
        }
        player.event.secondElapse.addListener(self) { [weak self] seconds in
            generation.performOnMainIfCurrent { [weak self] in
                self?.handleAudioPlayerSecondElapse(seconds: seconds)
            }
        }
        player.event.seek.addListener(self) { [weak self] event in
            generation.performOnMainIfCurrent { [weak self] in
                guard event.didFinish else { return }
                self?.finishSeeking(to: event.seconds)
            }
        }
        player.event.playWhenReadyChange.addListener(self) { [weak self] playWhenReady in
            generation.performOnMainIfCurrent { [weak self] in
                self?.handlePlayWhenReadyChange(playWhenReady: playWhenReady)
            }
        }
        player.event.didRecreateAVPlayer.addListener(self) { [weak self] _ in
            generation.performOnMainIfCurrent { [weak self] in
                guard let self = self else { return }
                self.playbackSession.invalidateForInterruption()
                self.configureAudioSession()
            }
        }
    }

    // MARK: - RCTEventEmitter
    private func emit(event: EventType, body: Any? = nil) {
        if event.rawValue.hasPrefix("remote-") {
            logTrackPlayerDevelopment("[CarPlay][Remote][Native] emit \(event.rawValue) body=\(String(describing: body))")
        }
        delegate?.sendEvent(name: event.rawValue, body: body)
    }

    // MARK: - AudioSessionControllerDelegate

    public func handleInterruption(type: InterruptionType) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.handleInterruption(type: type) }
            return
        }
        let generation = ownerGeneration
        generation.performOnMainIfCurrent { [weak self] in
            guard let self = self else { return }
            switch type {
            case .began:
                self.playbackSession.invalidateForInterruption()
                self.emit(event: EventType.RemoteDuck, body: ["paused": true])
            case .ended(let shouldResume):
                if self.playbackSession.requiresExplicitPlay {
                    self.emit(
                        event: EventType.RemoteDuck, body: ["paused": true, "permanent": false])
                    return
                }
                if shouldResume {
                    if self.shouldResumePlaybackAfterInterruptionEnds {
                        do {
                            try self.startPlayback(userInitiated: false)
                        } catch {
                            self.emitAudioSessionFailure(error)
                            return
                        }
                    }
                    self.emit(event: EventType.RemoteDuck, body: ["paused": false])
                } else {
                    self.emit(
                        event: EventType.RemoteDuck, body: ["paused": true, "permanent": true])
                }
            }
        }
    }

    // MARK: - Bridged Methods

    private func rejectWhenNotInitialized(reject: RCTPromiseRejectBlock) -> Bool {
        let rejected = !hasInitialized;
        if (rejected) {
            reject("player_not_initialized", "The player is not initialized. Call setupPlayer first.", nil)
        }
        return rejected;
    }

    private func rejectWhenTrackIndexOutOfBounds(
        index: Int,
        min: Int? = nil,
        max : Int? = nil,
        message : String? = "The track index is out of bounds",
        reject: RCTPromiseRejectBlock
    ) -> Bool {
        let rejected = index < (min ?? 0) || index > (max ?? player.items.count - 1);
        if (rejected) {
            reject("index_out_of_bounds", message, nil)
        }
        return rejected
    }

    @objc(setupPlayer:resolver:rejecter:)
    public func setupPlayer(config: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if hasInitialized {
            reject("player_already_initialized", "The player has already been initialized via setupPlayer.", nil)
            return
        }

        // configure buffer size
        if let bufferDuration = config["minBuffer"] as? TimeInterval {
            player.bufferDuration = bufferDuration
        }

        if let autoHandleInterruptions = config["autoHandleInterruptions"] as? Bool {
            self.shouldResumePlaybackAfterInterruptionEnds = autoHandleInterruptions
        }

        // configure wether control center metdata should auto update
        player.automaticallyUpdateNowPlayingInfo = config["autoUpdateMetadata"] as? Bool ?? true

        // configure audio session - category, options & mode
        if
            let sessionCategoryStr = config["iosCategory"] as? String,
            let mappedCategory = SessionCategory(rawValue: sessionCategoryStr) {
            sessionCategory = mappedCategory.mapConfigToAVAudioSessionCategory()
        }

        if
            let sessionCategoryModeStr = config["iosCategoryMode"] as? String,
            let mappedCategoryMode = SessionCategoryMode(rawValue: sessionCategoryModeStr) {
            sessionCategoryMode = mappedCategoryMode.mapConfigToAVAudioSessionCategoryMode()
        }

        if
            let sessionCategoryPolicyStr = config["iosCategoryPolicy"] as? String,
            let mappedCategoryPolicy = SessionCategoryPolicy(rawValue: sessionCategoryPolicyStr) {
            sessionCategoryPolicy = mappedCategoryPolicy.mapConfigToAVAudioSessionCategoryPolicy()
        }

        let sessionCategoryOptsStr = config["iosCategoryOptions"] as? [String]
        let mappedCategoryOpts = sessionCategoryOptsStr?.compactMap { SessionCategoryOptions(rawValue: $0)?.mapConfigToAVAudioSessionCategoryOptions() } ?? []
        sessionCategoryOptions = AVAudioSession.CategoryOptions(mappedCategoryOpts)

        do {
            try playbackSession.configure(prepareAudioSession)
        } catch {
            rejectAudioSessionFailure(error, reject: reject)
            return
        }
        configureRemoteCommands(player: player, generation: ownerGeneration)

        hasInitialized = true
        resolve(NSNull())
    }

    private func prepareAudioSession() throws {
        try configureSession(
            sessionCategory, sessionCategoryMode, sessionCategoryPolicy, sessionCategoryOptions)
    }

    private func startPlayback(userInitiated: Bool) throws {
        do {
            try playbackSession.activate(
                userInitiated: userInitiated, configureSession: prepareAudioSession)
            player.play()
        } catch {
            player.pause()
            throw error
        }
    }

    private func rejectAudioSessionFailure(_ error: Error, reject: RCTPromiseRejectBlock) {
        let sessionError = error as? AudioSessionPlaybackError
        reject(
            sessionError?.code ?? "audio_session_activation_failed", error.localizedDescription,
            error)
    }

    private func emitAudioSessionFailure(_ error: Error) {
        player.pause()
        let sessionError = error as? AudioSessionPlaybackError
        var body: [String: Any] = [
            "code": sessionError?.code ?? "audio_session_activation_failed",
            "message": error.localizedDescription,
        ]
        if let trackId = (player.currentItem as? Track)?.toObject()["id"] {
            body["trackId"] = trackId
        }
        emit(event: EventType.PlaybackError, body: body)
    }

    private func configureAudioSession() {
        do {
            if player.currentItem == nil {
                try playbackSession.deactivate()
            } else if player.playWhenReady && !playbackSession.isActive {
                try playbackSession.activate(
                    userInitiated: false, configureSession: prepareAudioSession)
            }
        } catch {
            emitAudioSessionFailure(error)
        }
    }

    private func synchronizeCurrentTrack() {
        guard cachedPositionTrack !== player.currentItem as? Track else { return }
        pendingSeekPosition = nil
        cachePosition(0)
        nowPlayingMetadata = [:]
    }

    private func cachePosition(_ seconds: Double) {
        guard seconds.isFinite && seconds >= 0 else { return }
        guard pendingSeekPosition == nil else { return }
        cachedPosition = seconds
        cachedPositionTrack = player.currentItem as? Track
    }

    private func latestUsablePosition() -> Double {
        if cachedPositionTrack !== player.currentItem as? Track {
            cachedPosition = 0
            pendingSeekPosition = nil
            cachedPositionTrack = player.currentItem as? Track
        }
        if let pendingSeekPosition = pendingSeekPosition { return pendingSeekPosition }
        let currentTime = player.currentTime
        if currentTime.isFinite && currentTime > 0 {
            cachePosition(currentTime)
        }
        return cachedPosition
    }

    private func beginSeeking(to seconds: Double) {
        guard seconds.isFinite && seconds >= 0 else { return }
        cachedPositionTrack = player.currentItem as? Track
        pendingSeekPosition = seconds
    }

    private func finishSeeking(to seconds: Double) {
        guard let pendingSeekPosition = pendingSeekPosition,
            abs(pendingSeekPosition - seconds) <= 0.001
        else { return }
        self.pendingSeekPosition = nil
        cachePosition(seconds)
    }

    func handleMediaServicesReset() {
        let snapshot = NativePlayerSnapshot(player: player, position: latestUsablePosition())
        let retiredPlayer = player
        ownerGeneration.invalidate()
        playbackSession.mediaServicesWereReset()
        retiredPlayer.remoteCommands = []
        retiredPlayer.syncRemoteCommandsWithCommandCenter()
        retiredPlayer.repeatMode = .off
        retiredPlayer.stop()
        retiredPlayer.clear()
        let generation = PlaybackOwnerGeneration()
        ownerGeneration = generation
        player = playerFactory(generation)
        configureRemoteCommands(player: player, generation: generation)
        do {
            try snapshot.restore(to: player)
            beginSeeking(to: snapshot.position)
            try playbackSession.configure(prepareAudioSession)
            if !nowPlayingMetadata.isEmpty {
                Metadata.update(for: player, with: nowPlayingMetadata)
            }
        } catch {
            emitAudioSessionFailure(error)
        }
        registerPlayerEvents(player: player, generation: generation)
        guard hasInitialized else { return }
        emit(event: EventType.RemoteDuck, body: ["paused": true, "permanent": false])
        emit(event: EventType.PlaybackPlayWhenReadyChanged, body: ["playWhenReady": false])
        emit(event: EventType.PlaybackState, body: ["state": State.paused.rawValue])
        if player.automaticallyUpdateNowPlayingInfo {
            MPNowPlayingInfoCenter.default().playbackState = .paused
        }
    }

    private func remoteHandler(
        player: QueuedAudioPlayer,
        generation: PlaybackOwnerGeneration,
        requiresCurrentItem: Bool = true,
        handler:
            @escaping (NativeTrackPlayerImpl, QueuedAudioPlayer, MPRemoteCommandEvent) ->
            MPRemoteCommandHandlerStatus
    ) -> RemoteCommandHandler {
        { [weak self, weak player] event in
            let handle = { () -> MPRemoteCommandHandlerStatus in
                guard generation.isCurrent, let self = self, let player = player,
                    !requiresCurrentItem || player.currentItem != nil
                else { return .noSuchContent }
                return handler(self, player, event)
            }
            return Thread.isMainThread ? handle() : DispatchQueue.main.sync(execute: handle)
        }
    }

    private func configureRemoteCommands(
        player: QueuedAudioPlayer, generation: PlaybackOwnerGeneration
    ) {
        let controller = player.remoteCommandController
        controller.handlePlayCommand = remoteHandler(player: player, generation: generation) {
            owner, _, _ in
            owner.emit(event: .RemotePlay)
            return .success
        }
        controller.handlePauseCommand = remoteHandler(player: player, generation: generation) {
            owner, _, _ in
            owner.emit(event: .RemotePause)
            return .success
        }
        controller.handleStopCommand = remoteHandler(player: player, generation: generation) {
            owner, _, _ in
            owner.emit(event: .RemoteStop)
            return .success
        }
        controller.handleNextTrackCommand = remoteHandler(player: player, generation: generation) {
            owner, _, _ in
            owner.emit(event: .RemoteNext)
            return .success
        }
        controller.handlePreviousTrackCommand = remoteHandler(
            player: player, generation: generation
        ) {
            owner, _, _ in
            owner.emit(event: .RemotePrevious)
            return .success
        }
        controller.handleTogglePlayPauseCommand = remoteHandler(
            player: player, generation: generation
        ) { owner, player, _ in
            owner.emit(event: player.playerState == .paused ? .RemotePlay : .RemotePause)
            return .success
        }
        controller.handleChangePlaybackPositionCommand = remoteHandler(
            player: player, generation: generation
        ) { owner, _, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            owner.emit(event: .RemoteSeek, body: ["position": event.positionTime])
            return .success
        }
        controller.handleSkipBackwardCommand = remoteHandler(player: player, generation: generation)
        {
            owner, _, event in
            guard let command = event.command as? MPSkipIntervalCommand,
                let interval = command.preferredIntervals.first
            else { return .commandFailed }
            owner.emit(event: .RemoteJumpBackward, body: ["interval": interval])
            return .success
        }
        controller.handleSkipForwardCommand = remoteHandler(player: player, generation: generation)
        {
            owner, _, event in
            guard let command = event.command as? MPSkipIntervalCommand,
                let interval = command.preferredIntervals.first
            else { return .commandFailed }
            owner.emit(event: .RemoteJumpForward, body: ["interval": interval])
            return .success
        }
        controller.handleLikeCommand = remoteHandler(
            player: player, generation: generation, requiresCurrentItem: false
        ) { owner, _, _ in
            owner.emit(event: .RemoteLike)
            return .success
        }
        controller.handleDislikeCommand = remoteHandler(
            player: player, generation: generation, requiresCurrentItem: false
        ) { owner, _, _ in
            owner.emit(event: .RemoteDislike)
            return .success
        }
        controller.handleBookmarkCommand = remoteHandler(
            player: player, generation: generation, requiresCurrentItem: false
        ) { owner, _, _ in
            owner.emit(event: .RemoteBookmark)
            return .success
        }
    }

    @objc(isServiceRunning:rejecter:)
    public func isServiceRunning(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        // TODO That is probably always true
        resolve(true)
    }

    @objc(updateOptions:resolver:rejecter:)
    public func update(options: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        var capabilitiesStr = options["capabilities"] as? [String] ?? []
        if (capabilitiesStr.contains("play") && capabilitiesStr.contains("pause")) {
            capabilitiesStr.append("togglePlayPause");
        }

        forwardJumpInterval = options["forwardJumpInterval"] as? NSNumber ?? forwardJumpInterval
        backwardJumpInterval = options["backwardJumpInterval"] as? NSNumber ?? backwardJumpInterval

        player.remoteCommands = capabilitiesStr
            .compactMap { Capability(rawValue: $0) }
            .map { capability in
                capability.mapToPlayerCommand(
                    forwardJumpInterval: forwardJumpInterval,
                    backwardJumpInterval: backwardJumpInterval,
                    likeOptions: options["likeOptions"] as? [String: Any],
                    dislikeOptions: options["dislikeOptions"] as? [String: Any],
                    bookmarkOptions: options["bookmarkOptions"] as? [String: Any]
                )
            }

        player.syncRemoteCommandsWithCommandCenter()
        logTrackPlayerDevelopment("[CarPlay][Remote][Native] updateOptions capabilities=\(capabilitiesStr) remoteCommands=\(player.remoteCommands.count)")

        configureProgressUpdateEvent(
            interval: ((options["progressUpdateEventInterval"] as? NSNumber) ?? 0).doubleValue
        )

        resolve(NSNull())
    }

    private func configureProgressUpdateEvent(interval: Double) {
        shouldEmitProgressEvent = interval > 0
        self.player.timeEventFrequency = shouldEmitProgressEvent
            ? .custom(time: CMTime(seconds: interval, preferredTimescale: 1000))
            : .everySecond
    }

    @objc
    public func add(
        trackDicts: [[String: Any]],
        before trackIndex: NSNumber,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        // -1 means no index was passed and therefore should be inserted at the end.
        let index = trackIndex.intValue == -1 ? player.items.count : trackIndex.intValue;
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(
            index: index,
            max: player.items.count,
            reject: reject
        )) { return }

        var tracks = [Track]()
        for trackDict in trackDicts {
            guard let track = Track(dictionary: trackDict) else {
                reject("invalid_track_object", "Track is missing a required key", nil)
                return
            }

            tracks.append(track)
        }

        try? player.add(
            items: tracks,
            at: index
        )
        resolve(index)
    }

    @objc
    public func load(
        trackDict: [String: Any],
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        guard let track = Track(dictionary: trackDict) else {
            reject("invalid_track_object", "Track is missing a required key", nil)
            return
        }

        player.load(item: track)
        synchronizeCurrentTrack()
        if player.automaticallyUpdateNowPlayingInfo {
            player.nowPlayingInfoController.set(
                keyValue: MediaItemProperty.duration(track.duration)
            )
        }
        resolve(player.currentIndex)
    }

    @objc
    public func remove(tracks indexes: [Int], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        for index in indexes {
            if (rejectWhenTrackIndexOutOfBounds(index: index, message: "One or more of the indexes were out of bounds.", reject: reject)) {
                return
            }
        }

        // Sort the indexes in descending order so we can safely remove them one by one
        // without having the next index possibly newly pointing to another item than intended:
        for index in indexes.sorted().reversed() {
            try? player.removeItem(at: index)
        }

        resolve(NSNull())
    }

    @objc
    public func move(
        fromIndex: Int,
        toIndex: Int,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(
            index: fromIndex,
            message: "The fromIndex is out of bounds",
            reject: reject)
        ) { return }
        if (rejectWhenTrackIndexOutOfBounds(
            index: toIndex,
            max: Int.max,
            message: "The toIndex is out of bounds",
            reject: reject)
        ) { return }
        try? player.moveItem(fromIndex: fromIndex, toIndex: toIndex)
        resolve(NSNull())
    }

    @objc
    public func removeUpcomingTracks(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.removeUpcomingItems()
        resolve(NSNull())
    }

    @objc
    public func skip(
        to trackIndex: Int,
        initialTime: Double,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenTrackIndexOutOfBounds(index: trackIndex, reject: reject)) { return }

        if (rejectWhenNotInitialized(reject: reject)) { return }

        logTrackPlayerDevelopment("Skipping to track: \(trackIndex)")
        try? player.jumpToItem(atIndex: trackIndex, playWhenReady: player.playerState == .playing)
        synchronizeCurrentTrack()

        // if an initialTime is passed the seek to it
        if (initialTime >= 0) {
            self.seekTo(time: initialTime, resolve: resolve, reject: reject)
        } else {
            resolve(NSNull())
        }
    }

    @objc
    public func skipToNext(
        initialTime: Double,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.next()
        synchronizeCurrentTrack()

        // if an initialTime is passed the seek to it
        if (initialTime >= 0) {
            self.seekTo(time: initialTime, resolve: resolve, reject: reject)
        } else {
            resolve(NSNull())
        }
    }

    @objc
    public func skipToPrevious(
        initialTime: Double,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.previous()
        synchronizeCurrentTrack()

        // if an initialTime is passed the seek to it
        if (initialTime >= 0) {
            self.seekTo(time: initialTime, resolve: resolve, reject: reject)
        } else {
            resolve(NSNull())
        }
    }

    @objc
    public func reset(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.stop()
        player.clear()
        resolve(NSNull())
    }

    private func performPlaybackCommand(
        resetRevision: UInt64?,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock,
        command: @escaping () throws -> Void
    ) {
        let perform = {
            if self.rejectWhenNotInitialized(reject: reject) { return }
            do {
                if let resetRevision = resetRevision {
                    try self.playbackSession.requireCurrentResetRevision(resetRevision)
                }
                try command()
                resolve(NSNull())
            } catch {
                self.rejectAudioSessionFailure(error, reject: reject)
            }
        }
        if Thread.isMainThread {
            perform()
        } else {
            DispatchQueue.main.async(execute: perform)
        }
    }

    @objc(playWithUserInitiated:resolve:reject:)
    public func play(
        userInitiated: Bool, resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let resetRevision = playbackSession.captureResetRevision()
        performPlaybackCommand(resetRevision: resetRevision, resolve: resolve, reject: reject) {
            try self.startPlayback(userInitiated: userInitiated)
        }
    }

    @objc
    public func pause(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.pause()
        resolve(NSNull())
    }

    @objc
    public func setPlayWhenReady(
        playWhenReady: Bool, resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let resetRevision = playWhenReady ? playbackSession.captureResetRevision() : nil
        performPlaybackCommand(resetRevision: resetRevision, resolve: resolve, reject: reject) {
            if playWhenReady {
                try self.startPlayback(userInitiated: true)
            } else {
                self.player.pause()
            }
        }
    }

    @objc
    public func getPlayWhenReady(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolve(player.playWhenReady)
    }

    @objc
    public func stop(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.stop()
        resolve(NSNull())
    }

    @objc
    public func seekTo(time: Double, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if rejectWhenNotInitialized(reject: reject) { return }

        beginSeeking(to: time)
        player.seek(to: time)
        resolve(NSNull())
    }

    @objc
    public func seekBy(
        offset: Double, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock
    ) {
        if rejectWhenNotInitialized(reject: reject) { return }

        beginSeeking(to: max(0, latestUsablePosition() + offset))
        player.seek(by: offset)
        resolve(NSNull())
    }

    @objc
    public func retry(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        player.reload(startFromCurrentTime: true)
        resolve(NSNull())
    }

    @objc
    public func setRepeatMode(repeatMode: NSNumber, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: repeatMode.intValue) ?? .off
        resolve(NSNull())
    }

    @objc
    public func getRepeatMode(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(player.repeatMode.rawValue)
    }

    @objc
    public func setVolume(level: Float, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.volume = level
        resolve(NSNull())
    }

    @objc
    public func getVolume(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(player.volume)
    }

    @objc
    public func setRate(rate: Float, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.rate = rate
        resolve(NSNull())
    }

    @objc
    public func getRate(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(player.rate)
    }

    @objc
    public func getTrack(index: Double, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        let indexInt = Int(index)
        if (indexInt >= 0 && indexInt < player.items.count) {
            let track = player.items[indexInt]
            resolve((track as? Track)?.toObject())
        } else {
            resolve(NSNull())
        }
    }

    @objc
    public func getQueue(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        let serializedQueue = player.items.map { ($0 as! Track).toObject() }
        resolve(serializedQueue)
    }

    @objc
    public func setQueue(
        trackDicts: [[String: Any]],
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        var tracks = [Track]()
        for trackDict in trackDicts {
            guard let track = Track(dictionary: trackDict) else {
                reject("invalid_track_object", "Track is missing a required key", nil)
                return
            }

            tracks.append(track)
        }
        player.clear()
        try? player.add(items: tracks)
        synchronizeCurrentTrack()
        resolve(index)
    }

    @objc
    public func getActiveTrack(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        let index = player.currentIndex
        if (index >= 0 && index < player.items.count) {
            let track = player.items[index]
            resolve((track as? Track)?.toObject())
        } else {
            resolve(NSNull())
        }
    }

    @objc
    public func getActiveTrackIndex(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        let index = player.currentIndex
        if index < 0 || index >= player.items.count {
            resolve(NSNull())
        } else {
            resolve(index)
        }
    }

    @objc
    public func getProgress(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolve([
            "position": player.currentTime,
            "duration": player.duration,
            "buffered": player.bufferedPosition
        ])
    }

    @objc
    public func getPlaybackState(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolve(getPlaybackStateBodyKeyValues(state: player.playerState))
    }

    @objc
    public func updateMetadata(for trackIndex: Int, metadata: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(index: trackIndex, reject: reject)) { return }

        let track : Track = player.items[trackIndex] as! Track;
        track.updateMetadata(dictionary: metadata)

        if (player.currentIndex == trackIndex) {
            nowPlayingMetadata = nowPlayingMetadata.merging(metadata) { _, new in new }
            Metadata.update(for: player, with: metadata)
        }

        resolve(NSNull())
    }

    @objc
    public func updateNowPlayingMetadata(
        metadata: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock
    ) {
        if rejectWhenNotInitialized(reject: reject) { return }

        nowPlayingMetadata = nowPlayingMetadata.merging(metadata) { _, new in new }
        Metadata.update(for: player, with: metadata)
        resolve(NSNull())
    }

    private func getPlaybackStateBodyKeyValues(state: AudioPlayerState) -> Dictionary<String, Any> {
        var body: Dictionary<String, Any> = ["state": State.fromPlayerState(state: state).rawValue]
        if (state == AudioPlayerState.failed) {
            body["error"] = getPlaybackErrorKeyValues(error: player.playbackError)
        }
        return body
    }

    // MARK: - QueuedAudioPlayer Event Handlers

    func handleAudioPlayerStateChange(state: AVPlayerWrapperState) {
        if player.automaticallyUpdateNowPlayingInfo {
            switch state {
            case .playing:
                MPNowPlayingInfoCenter.default().playbackState = .playing
            case .buffering, .loading:
                MPNowPlayingInfoCenter.default().playbackState =
                    player.playWhenReady ? .playing : .paused
            case .paused, .ready:
                MPNowPlayingInfoCenter.default().playbackState = .paused
            case .ended, .failed, .idle, .stopped:
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            }
        }

        emit(event: EventType.PlaybackState, body: getPlaybackStateBodyKeyValues(state: state))
        if state == .ended {
            emit(
                event: EventType.PlaybackQueueEnded,
                body: [
                    "track": player.currentIndex,
                    "position": player.currentTime,
                ] as [String: Any])
        }
    }

    func handleAudioPlayerCommonMetadataReceived(metadata: [AVMetadataItem]) {
        let commonMetadata = MetadataAdapter.convertToCommonMetadata(metadata: metadata, skipRaw: true)
        emit(event: EventType.MetadataCommonReceived, body: ["metadata": commonMetadata])
    }

    func handleAudioPlayerChapterMetadataReceived(metadata: [AVTimedMetadataGroup]) {
        let metadataItems = MetadataAdapter.convertToGroupedMetadata(metadataGroups: metadata);
        emit(event: EventType.MetadataChapterReceived, body:  ["metadata": metadataItems])
    }

    func handleAudioPlayerTimedMetadataReceived(metadata: [AVTimedMetadataGroup]) {
        let metadataItems = MetadataAdapter.convertToGroupedMetadata(metadataGroups: metadata);
        emit(event: EventType.MetadataTimedReceived, body: ["metadata": metadataItems])
    }

    func handleAudioPlayerFailed(error: Error?) {
        emit(event: EventType.PlaybackError, body: getPlaybackErrorKeyValues(error: error))
    }

    func handleAudioPlayerCurrentItemChange(
        item: AudioItem?,
        index: Int?,
        lastItem: AudioItem?,
        lastIndex: Int?,
        lastPosition: Double?
    ) {

        if index == player.currentIndex { synchronizeCurrentTrack() }
        if let item = item {
            UIApplication.shared.beginReceivingRemoteControlEvents()
            // Update now playing controller with isLiveStream option from track
            if self.player.automaticallyUpdateNowPlayingInfo {
                let isTrackLiveStream = (item as? Track)?.isLiveStream ?? false
                self.player.nowPlayingInfoController.set(
                    keyValue: NowPlayingInfoProperty.isLiveStream(isTrackLiveStream))
            }
        } else {
            UIApplication.shared.endReceivingRemoteControlEvents()
        }

        if (item != nil && lastItem == nil) || item == nil {
            configureAudioSession()
        }

        var a: [String: Any] = ["lastPosition": lastPosition ?? 0]
        if let lastIndex = lastIndex {
            a["lastIndex"] = lastIndex
        }

        if let lastTrack = (lastItem as? Track)?.toObject() {
            a["lastTrack"] = lastTrack
        }

        if let index = index {
            a["index"] = index
        }

        if let track = (item as? Track)?.toObject() {
            a["track"] = track
        }
        emit(event: EventType.PlaybackActiveTrackChanged, body: a)
    }

    func handleAudioPlayerSecondElapse(seconds: Double) {
        let currentTime = player.currentTime
        if currentTime > 0 { cachePosition(currentTime) }
        // because you cannot prevent the `event.secondElapse` from firing
        // do not emit an event if `progressUpdateEventInterval` is nil
        // additionally, there are certain instances in which this event is emitted
        // _after_ a manipulation to the queu causing no currentItem to exist (see reset)
        // in which case we shouldn't emit anything or we'll get an exception.
        if !shouldEmitProgressEvent || player.currentItem == nil { return }
        emit(
            event: EventType.PlaybackProgressUpdated,
            body: [
                "position": player.currentTime,
                "duration": player.duration,
                "buffered": player.bufferedPosition,
                "track": player.currentIndex,
            ]
        )
    }

    func handlePlayWhenReadyChange(playWhenReady: Bool) {
        guard playWhenReady == player.playWhenReady else { return }
        configureAudioSession()
        guard playWhenReady == player.playWhenReady else { return }
        emit(
            event: EventType.PlaybackPlayWhenReadyChanged,
            body: [
                "playWhenReady": playWhenReady
            ]
        )
    }
}

@objc public protocol NativeTrackPlayerImplDelegate {
    func sendEvent(name: String, body: Any)
}

extension NativeTrackPlayerImpl {
    @objc(constantsToExport)
    public static var constantsToExport: [AnyHashable: Any] {
        return [
            "STATE_NONE": State.none.rawValue,
            "STATE_READY": State.ready.rawValue,
            "STATE_PLAYING": State.playing.rawValue,
            "STATE_PAUSED": State.paused.rawValue,
            "STATE_STOPPED": State.stopped.rawValue,
            "STATE_BUFFERING": State.buffering.rawValue,
            "STATE_LOADING": State.loading.rawValue,
            "STATE_ERROR": State.error.rawValue,

            "TRACK_PLAYBACK_ENDED_REASON_END": PlaybackEndedReason.playedUntilEnd.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_JUMPED": PlaybackEndedReason.jumpedToIndex.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_NEXT": PlaybackEndedReason.skippedToNext.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_PREVIOUS": PlaybackEndedReason.skippedToPrevious.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_STOPPED": PlaybackEndedReason.playerStopped.rawValue,

            "PITCH_ALGORITHM_LINEAR": PitchAlgorithm.linear.rawValue,
            "PITCH_ALGORITHM_MUSIC": PitchAlgorithm.music.rawValue,
            "PITCH_ALGORITHM_VOICE": PitchAlgorithm.voice.rawValue,

            "CAPABILITY_PLAY": Capability.play.rawValue,
            "CAPABILITY_PLAY_FROM_ID": "NOOP",
            "CAPABILITY_PLAY_FROM_SEARCH": "NOOP",
            "CAPABILITY_PAUSE": Capability.pause.rawValue,
            "CAPABILITY_STOP": Capability.stop.rawValue,
            "CAPABILITY_SEEK_TO": Capability.seek.rawValue,
            "CAPABILITY_SKIP": "NOOP",
            "CAPABILITY_SKIP_TO_NEXT": Capability.next.rawValue,
            "CAPABILITY_SKIP_TO_PREVIOUS": Capability.previous.rawValue,
            "CAPABILITY_SET_RATING": "NOOP",
            "CAPABILITY_JUMP_FORWARD": Capability.jumpForward.rawValue,
            "CAPABILITY_JUMP_BACKWARD": Capability.jumpBackward.rawValue,
            "CAPABILITY_LIKE": Capability.like.rawValue,
            "CAPABILITY_DISLIKE": Capability.dislike.rawValue,
            "CAPABILITY_BOOKMARK": Capability.bookmark.rawValue,

            "REPEAT_OFF": RepeatMode.off.rawValue,
            "REPEAT_TRACK": RepeatMode.track.rawValue,
            "REPEAT_QUEUE": RepeatMode.queue.rawValue,
        ]
    }

    @objc(supportedEvents)
    public static var supportedEvents: [String] {
        var events = EventType.allRawValues()

        // Stub out events that are only supported on Android
        events.append("remote-play-pause")

        return events
    }
}
