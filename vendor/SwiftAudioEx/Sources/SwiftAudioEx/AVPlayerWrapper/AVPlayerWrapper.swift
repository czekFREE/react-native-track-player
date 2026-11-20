//
//  AVPlayerWrapper.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 06/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer

public enum PlaybackEndedReason: String {
    case playedUntilEnd
    case playerStopped
    case skippedToNext
    case skippedToPrevious
    case jumpedToIndex
    case cleared
    case failed
}

private enum LoadedMetadataEvent {
    case common([AVMetadataItem])
    case chapter([AVTimedMetadataGroup])
    case timed([AVTimedMetadataGroup])

    var items: [AVMetadataItem] {
        switch self {
        case .common(let items): return items
        case .chapter(let groups), .timed(let groups): return groups.flatMap { $0.items }
        }
    }

    func replacingItems(with snapshots: [ObjectIdentifier: AVMetadataItem]) -> LoadedMetadataEvent {
        func preparedItems(_ items: [AVMetadataItem]) -> [AVMetadataItem] {
            items.compactMap { snapshots[ObjectIdentifier($0)] }
        }
        func preparedGroups(_ groups: [AVTimedMetadataGroup]) -> [AVTimedMetadataGroup] {
            groups.map {
                AVTimedMetadataGroup(items: preparedItems($0.items), timeRange: $0.timeRange)
            }
        }
        switch self {
        case .common(let items): return .common(preparedItems(items))
        case .chapter(let groups): return .chapter(preparedGroups(groups))
        case .timed(let groups): return .timed(preparedGroups(groups))
        }
    }
}

class AVPlayerWrapper: AVPlayerWrapperProtocol {
    // MARK: - Properties
    
    fileprivate var avPlayer: AVPlayer
    private let transportIntent: AVPlayerTransportIntent
    private let timelineEvents: AVPlayerEventRevision
    private let playerObserver: AVPlayerObserver
    internal let playerTimeObserver: AVPlayerTimeObserver
    private let playerItemNotificationObserver: AVPlayerItemNotificationObserver
    private let playerItemObserver: AVPlayerItemObserver
    private struct SeekRequest {
        let id = UUID()
        let seconds: TimeInterval
        let completionHandler: ((Bool) -> Void)?
        let blocksPlayback: Bool
        let shouldResumePlayback: (() -> Bool)?
        let sourceRevision: UUID
        let commandRevision: UUID
        var hasStarted = false

        init(
            seconds: TimeInterval, completionHandler: ((Bool) -> Void)?, blocksPlayback: Bool,
            shouldResumePlayback: (() -> Bool)? = nil, intent: AVPlayerTransportIntent.Snapshot
        ) {
            self.seconds = max(0, seconds)
            self.completionHandler = completionHandler
            self.blocksPlayback = blocksPlayback
            self.shouldResumePlayback = shouldResumePlayback
            self.sourceRevision = intent.sourceRevision
            self.commandRevision = intent.commandRevision
        }
    }
    private struct StalledSource {
        let revision: UUID
        let item: AVPlayerItem
    }
    private struct FailedSeekResumePosition {
        let sourceRevision: UUID
        let seconds: TimeInterval
    }
    private enum PlaybackInterruption {
        case unrestricted
        case interrupted
        case awaitingPlay

        var blocksPlayback: Bool {
            switch self {
            case .unrestricted: return false
            case .interrupted, .awaitingPlay: return true
            }
        }
    }
    private var stalledSource: StalledSource?
    private var playbackInterruption = PlaybackInterruption.unrestricted
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var seekRequest: SeekRequest?
    private var failedSeekResumePosition: FailedSeekResumePosition?
    private var seekRevision = UUID()
    private(set) var loadRevision = UUID()
    fileprivate var asset: AVAsset? = nil
    fileprivate var item: AVPlayerItem? = nil
    fileprivate var url: URL? = nil
    fileprivate var urlOptions: [String: Any]? = nil
    private static let metadataQueue = DispatchQueue(label: "AVPlayerWrapper.metadata")
    private let makeAsset: (URL, [String: Any]?) -> AVAsset
    private let makePlayerItem: (AVAsset, [String]) -> AVPlayerItem
    private var pendingTimedMetadata: [[AVTimedMetadataGroup]] = []
    private var isPreparingTimedMetadata = false
    private let stateQueue = DispatchQueue(
        label: "AVPlayerWrapper.stateQueue",
        attributes: .concurrent
    )

    init(
        player: AVPlayer = AVPlayer(),
        makeAsset: @escaping (URL, [String: Any]?) -> AVAsset = { AVURLAsset(url: $0, options: $1) },
        makePlayerItem: @escaping (AVAsset, [String]) -> AVPlayerItem = {
            AVPlayerItem(asset: $0, automaticallyLoadedAssetKeys: $1)
        }
    ) {
        let transportIntent = AVPlayerTransportIntent()
        let timelineEvents = AVPlayerEventRevision()
        self.transportIntent = transportIntent
        self.timelineEvents = timelineEvents
        avPlayer = player
        self.makeAsset = makeAsset
        self.makePlayerItem = makePlayerItem
        playerObserver = AVPlayerObserver(transportIntent: transportIntent)
        playerItemObserver = AVPlayerItemObserver(transportIntent: transportIntent)
        playerItemNotificationObserver = AVPlayerItemNotificationObserver(timelineEvents: timelineEvents)
        playerTimeObserver = AVPlayerTimeObserver(periodicObserverTimeInterval: timeEventFrequency.getTime())

        playerObserver.delegate = self
        playerTimeObserver.delegate = self
        playerItemNotificationObserver.delegate = self
        playerItemObserver.delegate = self

        setupAVPlayer();
        observeAudioSession()
    }

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - AVPlayerWrapperProtocol

    fileprivate(set) var playbackError: AudioPlayerError.PlaybackError? = nil
    
    private var _state: AVPlayerWrapperState = AVPlayerWrapperState.idle
    var state: AVPlayerWrapperState {
        get { stateQueue.sync { _state } }
        set {
            let changed = stateQueue.sync(flags: .barrier) {
                guard _state != newValue else { return false }
                _state = newValue
                return true
            }
            if changed { delegate?.AVWrapper(didChangeState: newValue) }
        }
    }

    fileprivate(set) var lastPlayerTimeControlStatus: AVPlayer.TimeControlStatus = AVPlayer.TimeControlStatus.paused

    /**
     Whether AVPlayer should start playing automatically when the item is ready.
     */
    public var playWhenReady: Bool {
        get { transportIntent.current.playWhenReady }
        set {
            let oldValue = playWhenReady
            if !newValue { stalledSource = nil }
            transportIntent.update(playWhenReady: newValue)
            if newValue && avPlayer.timeControlStatus == .paused {
                retainPlaybackForStall()
                resumeStalledPlaybackIfReady()
            }
            if (playWhenReady == true && (state == .failed || state == .stopped)) {
                reload(startFromCurrentTime: state == .failed || pendingSeekPosition != nil)
            }

            applyAVPlayerRate()
            
            if oldValue != playWhenReady {
                delegate?.AVWrapper(didChangePlayWhenReady: playWhenReady)
            }
        }
    }
    
    var currentItem: AVPlayerItem? {
        avPlayer.currentItem
    }

    var playbackActive: Bool {
        switch state {
        case .idle, .stopped, .ended, .failed:
            return false
        default: return true
        }
    }
    
    var pendingSeekPosition: TimeInterval? { seekRequest?.seconds }

    var recoveryPosition: TimeInterval? {
        if let pendingSeekPosition = pendingSeekPosition { return pendingSeekPosition }
        guard let failedSeekResumePosition = failedSeekResumePosition,
            failedSeekResumePosition.sourceRevision == transportIntent.current.sourceRevision
        else { return nil }
        return failedSeekResumePosition.seconds
    }

    var currentTime: TimeInterval {
        let seconds = avPlayer.currentTime().seconds
        return seconds.isNaN ? 0 : seconds
    }
    
    var duration: TimeInterval {
        if let currentItem = currentItem,
            currentItem.asset.statusOfValue(forKey: "duration", error: nil) == .loaded
        {
            let seconds = currentItem.asset.duration.seconds
            if !seconds.isNaN { return seconds }
        }
        if let seconds = currentItem?.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.seekableTimeRanges.last?.timeRangeValue.duration.seconds,
                !seconds.isNaN {
            return seconds
        }
        return 0.0
    }
    
    var bufferedPosition: TimeInterval {
        currentItem?.loadedTimeRanges.last?.timeRangeValue.end.seconds ?? 0
    }

    var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        avPlayer.reasonForWaitingToPlay
    }

    private var _rate: Float = 1.0;
    var rate: Float {
        get { _rate }
        set {
            _rate = newValue
            if avPlayer.timeControlStatus != .paused {
                applyAVPlayerRate()
            }
        }
    }

    weak var delegate: AVPlayerWrapperDelegate? = nil
    
    var bufferDuration: TimeInterval = 0 {
        didSet { currentItem?.preferredForwardBufferDuration = bufferDuration }
    }

    var timeEventFrequency: TimeEventFrequency = .everySecond {
        didSet {
            playerTimeObserver.periodicObserverTimeInterval = timeEventFrequency.getTime()
        }
    }
    
    var volume: Float {
        get { avPlayer.volume }
        set { avPlayer.volume = newValue }
    }
    
    var isMuted: Bool {
        get { avPlayer.isMuted }
        set { avPlayer.isMuted = newValue }
    }

    var automaticallyWaitsToMinimizeStalling: Bool {
        get { avPlayer.automaticallyWaitsToMinimizeStalling }
        set { avPlayer.automaticallyWaitsToMinimizeStalling = newValue }
    }

    var automaticallyPausesOnRouteLoss: Bool {
        get { transportIntent.current.automaticallyPausesOnRouteLoss }
        set { transportIntent.setAutomaticallyPausesOnRouteLoss(newValue) }
    }

    var playbackPermission: (() -> Bool)? {
        get { transportIntent.playbackPermission }
        set { transportIntent.playbackPermission = newValue }
    }
    
    func play() {
        playbackInterruption = .unrestricted
        playWhenReady = true
    }
    
    func pause() {
        playWhenReady = false
        if !playWhenReady && avPlayer.timeControlStatus == .paused
            && (state == .buffering || state == .playing) {
            state = .paused
        }
    }
    
    func togglePlaying() {
        let state = self.state
        if playWhenReady && state != .paused && state != .ended {
            pause()
        } else {
            play()
        }
    }
    
    func stop() {
        let revision = UUID()
        loadRevision = revision
        state = .stopped
        guard loadRevision == revision else { return }
        clearCurrentItem()
        guard loadRevision == revision else { return }
        playWhenReady = false
    }
    
    func seek(to seconds: TimeInterval, completionHandler: ((Bool) -> Void)? = nil) {
        seek(to: seconds, shouldResumePlayback: nil, completionHandler: completionHandler)
    }

    func seek(
        to seconds: TimeInterval, shouldResumePlayback: (() -> Bool)?,
        completionHandler: ((Bool) -> Void)?
    ) {
        failedSeekResumePosition = nil
        timelineEvents.advance()
        let previousRequest = seekRequest
        let request = SeekRequest(
            seconds: seconds, completionHandler: completionHandler,
            blocksPlayback: previousRequest?.blocksPlayback == true || avPlayer.currentItem == nil
                || shouldResumePlayback != nil,
            shouldResumePlayback: shouldResumePlayback, intent: transportIntent.current
        )
        seekRequest = request
        seekRevision = request.id
        if request.blocksPlayback { applyAVPlayerRate() }
        cancelSeek(previousRequest)
        guard seekRequest?.id == request.id else { return }
        performSeekIfReady()
    }

    private func performSeekIfReady() {
        guard playbackError == nil, let request = seekRequest, !request.hasStarted,
            let item = avPlayer.currentItem, self.item === item else { return }
        seekRequest?.hasStarted = true
        let player = avPlayer
        let time = CMTimeMakeWithSeconds(request.seconds, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, self.seekRequest?.id == request.id else { return }
                if !finished, request.blocksPlayback, request.shouldResumePlayback == nil,
                    self.isCurrentSeek(request, player: player, item: item) {
                    self.playbackFailed(error: .playbackFailed)
                    return
                }
                self.seekRequest = nil
                if request.blocksPlayback, self.avPlayer === player,
                    self.avPlayer.currentItem === item {
                    if let shouldResumePlayback = request.shouldResumePlayback,
                        self.transportIntent.current.commandRevision == request.commandRevision,
                        !finished || !shouldResumePlayback() {
                        self.pause()
                    } else {
                        self.applyAVPlayerRate()
                    }
                }
                let didFinish = finished && self.isCurrentSeek(request, player: player, item: item)
                self.delegate?.AVWrapper(seekTo: request.seconds, didFinish: didFinish)
                request.completionHandler?(didFinish && self.isCurrentSeek(request, player: player, item: item))
            }
        }
    }

    private func isCurrentSeek(_ request: SeekRequest, player: AVPlayer, item: AVPlayerItem) -> Bool {
        seekRevision == request.id && playbackError == nil && avPlayer === player && avPlayer.currentItem === item
    }

    private func cancelSeek(_ request: SeekRequest?) {
        guard let request = request else { return }
        let deliver = { [weak self] in
            if request.hasStarted {
                self?.delegate?.AVWrapper(seekTo: request.seconds, didFinish: false)
            }
            request.completionHandler?(false)
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    func seek(by seconds: TimeInterval) {
        seek(to: (seekRequest?.seconds ?? currentTime) + seconds)
    }

    private func playbackFailed(error: AudioPlayerError.PlaybackError) {
        guard playbackError == nil else { return }
        self.playbackError = error
        stalledSource = nil
        let failedRevision = loadRevision
        let cancelledRequest = seekRequest
        if let cancelledRequest = cancelledRequest,
            cancelledRequest.sourceRevision == transportIntent.current.sourceRevision {
            failedSeekResumePosition = FailedSeekResumePosition(
                sourceRevision: cancelledRequest.sourceRevision, seconds: cancelledRequest.seconds
            )
        }
        seekRequest = nil
        state = .failed
        if state == .failed && loadRevision == failedRevision {
            self.delegate?.AVWrapper(failedWithError: error)
        }
        cancelSeek(cancelledRequest)
    }

    func load(
        revision: UUID = UUID(), initialTime: TimeInterval? = nil, transferringDeferredSeek deferredSeekID: UUID? = nil
    ) {
        if url == nil, case .invalidSourceUrl? = playbackError { return }
        loadRevision = revision
        if (state == .failed || avPlayer.status == .failed) {
            recreateAVPlayer(revision: revision, initialTime: initialTime, transferringDeferredSeek: deferredSeekID)
        } else {
            clearCurrentItem(initialTime: initialTime, transferringDeferredSeek: deferredSeekID)
        }
        guard loadRevision == revision else { return }
        playbackError = nil
        if let url = url {
            let pendingAsset = makeAsset(url, urlOptions)
            asset = pendingAsset
            state = .loading
            guard loadRevision == revision, asset === pendingAsset else { return }

            let metadataKeys = [
                "commonMetadata", "availableChapterLocales", "availableMetadataFormats", "duration",
            ]
            pendingAsset.loadValuesAsynchronously(forKeys: metadataKeys) { [weak self] in
                Self.metadataQueue.async {
                    Self.collectMetadata(from: pendingAsset) { events in
                        DispatchQueue.main.async { [weak self] in
                            self?.deliver(events, for: pendingAsset)
                        }
                    }
                }
            }

            // Load playable portion of the track and commence when ready
            let playableKeys = ["playable"]
            pendingAsset.loadValuesAsynchronously(forKeys: playableKeys, completionHandler: { [weak self] in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    guard self.loadRevision == revision, self.asset === pendingAsset else { return }
                    
                    for key in playableKeys {
                        var error: NSError?
                        let keyStatus = pendingAsset.statusOfValue(forKey: key, error: &error)
                        switch keyStatus {
                        case .failed:
                            self.playbackFailed(error: AudioPlayerError.PlaybackError.failedToLoadKeyValue)
                            return
                        case .cancelled, .loading, .unknown:
                            return
                        case .loaded:
                            break
                        default: break
                        }
                    }
                    
                    if (!pendingAsset.isPlayable) {
                        self.playbackFailed(error: AudioPlayerError.PlaybackError.itemWasUnplayable)
                        return;
                    }
                    
                    let item = self.makePlayerItem(pendingAsset, playableKeys)
                    self.item = item;
                    item.preferredForwardBufferDuration = self.bufferDuration
                    let installedIntent = self.transportIntent.bind(item: item)
                    self.avPlayer.replaceCurrentItem(with: item)
                    guard self.loadRevision == revision, self.item === item,
                        self.avPlayer.currentItem === item else { return }
                    self.transportIntent.recordPlaybackAcceptance(
                        status: self.avPlayer.timeControlStatus,
                        item: item, observed: installedIntent
                    )
                    self.delegate?.AVWrapper(didInstallItem: item)
                    guard self.loadRevision == revision, self.item === item else { return }
                    self.startObservingAVPlayer(item: item)
                    guard self.item === item else { return }
                    self.applyAVPlayerRate()
                    
                    self.performSeekIfReady()
                }
            })
        }
    }
    
    func load(from url: URL, playWhenReady: Bool, options: [String: Any]? = nil) {
        load(from: url, playWhenReady: playWhenReady, initialTime: nil, options: options)
    }

    func load(
        from url: URL,
        playWhenReady: Bool,
        initialTime: TimeInterval? = nil,
        options: [String : Any]? = nil
    ) {
        self.url = url
        self.urlOptions = options
        let revision = UUID()
        let intentRevision = transportIntent.current.commandRevision
        self.load(revision: revision, initialTime: initialTime)
        guard loadRevision == revision else { return }
        if transportIntent.current.commandRevision == intentRevision {
            self.playWhenReady = playWhenReady
        }
    }

    func load(
        from url: String,
        type: SourceType = .stream,
        playWhenReady: Bool = false,
        initialTime: TimeInterval? = nil,
        options: [String : Any]? = nil
    ) {
        if let itemUrl = type == .file
            ? URL(fileURLWithPath: url)
            : URL(string: url)
        {
            self.load(from: itemUrl, playWhenReady: playWhenReady, initialTime: initialTime, options: options)
        } else {
            let revision = UUID()
            loadRevision = revision
            self.url = nil
            self.urlOptions = nil
            clearCurrentItem()
            guard loadRevision == revision else { return }
            playbackError = nil
            playbackFailed(error: AudioPlayerError.PlaybackError.invalidSourceUrl(url))
        }
    }

    func unload() {
        let revision = UUID()
        loadRevision = revision
        url = nil
        urlOptions = nil
        clearCurrentItem()
        guard loadRevision == revision else { return }
        state = .idle
    }

    func reload(startFromCurrentTime: Bool) {
        var time : Double? = nil
        if (startFromCurrentTime) {
            if let recoveryPosition = recoveryPosition {
                time = recoveryPosition
            } else if let currentItem = currentItem {
                if (!currentItem.duration.isIndefinite) {
                    time = currentItem.currentTime().seconds
                }
            }
        }
        let deferredSeekID = startFromCurrentTime && state == .stopped ? seekRequest?.id : nil
        load(initialTime: time, transferringDeferredSeek: deferredSeekID)
    }
    
    // MARK: - Util

    private func clearCurrentItem(
        initialTime: TimeInterval? = nil, transferringDeferredSeek deferredSeekID: UUID? = nil
    ) {
        transportIntent.retireSource()
        stalledSource = nil
        failedSeekResumePosition = nil
        timelineEvents.advance()
        let retiredAsset = asset
        self.asset = nil
        self.item = nil
        let transferredRequest = seekRequest.flatMap { request in
            request.id == deferredSeekID && !request.hasStarted ? request : nil
        }
        let cancelledRequest = transferredRequest == nil ? seekRequest : nil
        seekRequest = (transferredRequest?.seconds ?? initialTime).map {
            SeekRequest(
                seconds: $0, completionHandler: transferredRequest?.completionHandler,
                blocksPlayback: true, shouldResumePlayback: transferredRequest?.shouldResumePlayback,
                intent: transportIntent.current
            )
        }
        seekRevision = seekRequest?.id ?? UUID()
        if seekRequest?.blocksPlayback == true { applyAVPlayerRate() }
        pendingTimedMetadata.removeAll()
        isPreparingTimedMetadata = false
        stopObservingAVPlayerItem()
        avPlayer.currentItem?.cancelPendingSeeks()
        playerTimeObserver.unregisterForBoundaryTimeEvents()
        playerTimeObserver.unregisterForPeriodicEvents()
        avPlayer.replaceCurrentItem(with: nil)
        retiredAsset?.cancelLoading()
        cancelSeek(cancelledRequest)
    }
    
    private static func collectMetadata(
        from asset: AVAsset, completion: @escaping ([LoadedMetadataEvent]) -> Void
    ) {
        var events: [LoadedMetadataEvent] = []
        if asset.statusOfValue(forKey: "commonMetadata", error: nil) == .loaded {
            let items = asset.commonMetadata
            if !items.isEmpty { events.append(.common(items)) }
        }
        guard asset.statusOfValue(forKey: "availableChapterLocales", error: nil) == .loaded else {
            prepareMetadata(events, completion: completion)
            return
        }
        let locales = asset.availableChapterLocales
        if !locales.isEmpty {
            for locale in locales {
                let groups = asset.chapterMetadataGroups(
                    withTitleLocale: locale, containingItemsWithCommonKeys: nil)
                events.append(.chapter(groups))
            }
            prepareMetadata(events, completion: completion)
            return
        }
        guard asset.statusOfValue(forKey: "availableMetadataFormats", error: nil) == .loaded else {
            prepareMetadata(events, completion: completion)
            return
        }
        let formats = asset.availableMetadataFormats
        let duration =
            asset.statusOfValue(forKey: "duration", error: nil) == .loaded
            ? asset.duration : .invalid
        let timeRange = CMTimeRange(start: .zero, end: duration)
        let group = DispatchGroup()
        var formatEvents = [LoadedMetadataEvent?](repeating: nil, count: formats.count)
        for (index, format) in formats.enumerated() {
            if #available(iOS 15, macOS 12, tvOS 15, watchOS 8, *) {
                group.enter()
                asset.loadMetadata(for: format) { items, _ in
                    metadataQueue.async {
                        if let items = items {
                            formatEvents[index] = .timed([
                                AVTimedMetadataGroup(items: items, timeRange: timeRange)
                            ])
                        }
                        group.leave()
                    }
                }
            } else {
                let items = asset.metadata(forFormat: format)
                formatEvents[index] = .timed([
                    AVTimedMetadataGroup(items: items, timeRange: timeRange)
                ])
            }
        }
        let initialEvents = events
        group.notify(queue: metadataQueue) {
            prepareMetadata(initialEvents + formatEvents.compactMap { $0 }, completion: completion)
        }
    }

    private static func prepareMetadata(
        _ events: [LoadedMetadataEvent], completion: @escaping ([LoadedMetadataEvent]) -> Void
    ) {
        let group = DispatchGroup()
        var snapshots: [ObjectIdentifier: AVMetadataItem] = [:]
        for item in events.flatMap({ $0.items }) {
            group.enter()
            item.loadValuesAsynchronously(forKeys: ["value", "extraAttributes"]) {
                metadataQueue.async {
                    if item.statusOfValue(forKey: "value", error: nil) == .loaded,
                        item.statusOfValue(forKey: "extraAttributes", error: nil) == .loaded,
                        let mutableCopy = item.mutableCopy() as? AVMutableMetadataItem,
                        let snapshot = mutableCopy.copy() as? AVMetadataItem
                    {
                        snapshots[ObjectIdentifier(item)] = snapshot
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: metadataQueue) {
            let preparedEvents = events.map { $0.replacingItems(with: snapshots) }.filter {
                if case .common(let items) = $0 { return !items.isEmpty }
                return true
            }
            completion(preparedEvents)
        }
    }

    private func deliver(_ events: [LoadedMetadataEvent], for asset: AVAsset) {
        for event in events {
            guard self.asset === asset else { return }
            switch event {
            case .common(let items): delegate?.AVWrapper(didReceiveCommonMetadata: items)
            case .chapter(let groups): delegate?.AVWrapper(didReceiveChapterMetadata: groups)
            case .timed(let groups): delegate?.AVWrapper(didReceiveTimedMetadata: groups)
            }
        }
    }

    private func prepareNextTimedMetadata(for asset: AVAsset) {
        guard !isPreparingTimedMetadata, !pendingTimedMetadata.isEmpty else { return }
        let metadata = pendingTimedMetadata.removeFirst()
        isPreparingTimedMetadata = true
        Self.metadataQueue.async {
            Self.prepareMetadata([.timed(metadata)]) { [weak self] events in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.asset === asset else { return }
                    self.isPreparingTimedMetadata = false
                    self.deliver(events, for: asset)
                    guard self.asset === asset else { return }
                    self.prepareNextTimedMetadata(for: asset)
                }
            }
        }
    }

    private func startObservingAVPlayer(item: AVPlayerItem) {
        playerItemObserver.startObserving(item: item)
        guard self.item === item else { return }
        playerItemNotificationObserver.startObserving(item: item)
        playerTimeObserver.registerForBoundaryTimeEvents()
        playerTimeObserver.registerForPeriodicTimeEvents()
    }

    private func stopObservingAVPlayerItem() {
        playerItemObserver.stopObservingCurrentItem()
        playerItemNotificationObserver.stopObservingCurrentItem()
    }
    
    private func recreateAVPlayer(
        revision: UUID, initialTime: TimeInterval?, transferringDeferredSeek deferredSeekID: UUID?
    ) {
        playbackError = nil
        playerTimeObserver.unregisterForBoundaryTimeEvents()
        playerTimeObserver.unregisterForPeriodicEvents()
        playerObserver.stopObserving()
        stopObservingAVPlayerItem()
        clearCurrentItem(initialTime: initialTime, transferringDeferredSeek: deferredSeekID)
        guard loadRevision == revision else { return }

        let volume = avPlayer.volume
        let isMuted = avPlayer.isMuted
        let automaticallyWaitsToMinimizeStalling = avPlayer.automaticallyWaitsToMinimizeStalling
        avPlayer = AVPlayer()
        avPlayer.volume = volume
        avPlayer.isMuted = isMuted
        avPlayer.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
        setupAVPlayer()

        delegate?.AVWrapperDidRecreateAVPlayer()
    }
    
    private func setupAVPlayer() {
        // disabled since we're not making use of video playback
        avPlayer.allowsExternalPlayback = false;

        playerObserver.player = avPlayer
        playerObserver.startObserving()

        playerTimeObserver.player = avPlayer
        playerTimeObserver.registerForBoundaryTimeEvents()
        playerTimeObserver.registerForPeriodicTimeEvents()

        applyAVPlayerRate()
    }
    
    private func observeAudioSession() {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let notificationCenter = NotificationCenter.default
        audioSessionObservers = [
            notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
            ) { [weak self] notification in
                guard let self = self,
                    let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                let observed = self.transportIntent.current
                let deliver = { [weak self] in
                    guard let self = self,
                        self.transportIntent.current.sourceRevision == observed.sourceRevision,
                        self.transportIntent.current.commandRevision == observed.commandRevision
                    else { return }
                    switch type {
                    case .began:
                        self.playbackInterruption = .interrupted
                        self.stalledSource = nil
                        self.applyAVPlayerRate()
                    case .ended:
                        if case .interrupted = self.playbackInterruption {
                            self.playbackInterruption = .awaitingPlay
                        }
                    @unknown default: break
                    }
                }
                if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
            },
            notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
            ) { [weak self] notification in
                guard let self = self,
                    let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                    AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
                else { return }
                let observed = self.transportIntent.current
                guard observed.automaticallyPausesOnRouteLoss else { return }
                let deliver = { [weak self] in
                    guard let self = self else { return }
                    let current = self.transportIntent.current
                    guard current.automaticallyPausesOnRouteLoss,
                        current.sourceRevision == observed.sourceRevision,
                        current.commandRevision == observed.commandRevision
                    else { return }
                    self.pause()
                }
                if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
            },
        ]
        #endif
    }

    @discardableResult
    private func retainPlaybackForStall(bufferEmpty: Bool? = nil) -> Bool {
        guard !automaticallyWaitsToMinimizeStalling, playWhenReady, playbackActive,
            !playbackInterruption.blocksPlayback, playbackError == nil,
            let item = currentItem, self.item === item,
            bufferEmpty ?? item.isPlaybackBufferEmpty
        else { return false }
        let duration = item.duration.seconds
        guard !duration.isFinite || duration <= 0 || currentTime < duration else { return false }
        stalledSource = StalledSource(revision: transportIntent.current.sourceRevision, item: item)
        state = .buffering
        return true
    }

    private func resumeStalledPlaybackIfReady() {
        guard let stalledSource = stalledSource,
            transportIntent.current.sourceRevision == stalledSource.revision,
            currentItem === stalledSource.item,
            !stalledSource.item.isPlaybackBufferEmpty,
            stalledSource.item.isPlaybackLikelyToKeepUp || stalledSource.item.isPlaybackBufferFull,
            playWhenReady, !playbackInterruption.blocksPlayback, playbackError == nil else { return }
        self.stalledSource = nil
        state = .ready
        guard transportIntent.current.sourceRevision == stalledSource.revision,
            currentItem === stalledSource.item, playWhenReady, !playbackInterruption.blocksPlayback,
            playbackError == nil else { return }
        applyAVPlayerRate()
    }

    private var isPlaybackPermitted: Bool {
        playWhenReady && playbackError == nil && seekRequest?.blocksPlayback != true
            && stalledSource == nil && !playbackInterruption.blocksPlayback
            && (playbackPermission?() ?? true)
    }

    private func applyAVPlayerRate() {
        let intent = transportIntent.current
        avPlayer.rate = isPlaybackPermitted ? _rate : 0
        transportIntent.recordPlaybackAcceptance(
            status: avPlayer.timeControlStatus,
            item: avPlayer.currentItem, observed: intent
        )
    }
}

extension AVPlayerWrapper: AVPlayerObserverDelegate {
    
    // MARK: - AVPlayerObserverDelegate
    
    func player(didChangeTimeControlStatus status: AVPlayer.TimeControlStatus) {
        guard playbackError == nil else { return }
        switch status {
        case .paused:
            let state = self.state
            if self.asset == nil && state != .stopped {
                self.state = .idle
            } else if (state != .failed && state != .stopped) {
                // Playback may have become paused externally for example due to a bluetooth device disconnecting:
                if (self.playWhenReady) {
                    if playbackInterruption.blocksPlayback {
                        self.state = .paused
                        return
                    }
                    if seekRequest?.blocksPlayback == true { return }
                    let position = self.currentTime
                    let itemDuration = self.currentItem?.duration.seconds ?? .nan
                    let isAtEnd = itemDuration.isFinite && itemDuration > 0 && position >= itemDuration
                    if !isAtEnd && retainPlaybackForStall() { return }
                    if (position > 0 || transportIntent.current.hasAcceptedPlayback) && !isAtEnd {
                        let revision = loadRevision
                        self.playWhenReady = false
                        guard self.loadRevision == revision, !self.playWhenReady,
                            self.playbackError == nil else { return }
                        self.state = .paused
                    }
                } else if state != .loading && state != .ready {
                    self.state = .paused
                }
            }
        case .waitingToPlayAtSpecifiedRate:
            if self.asset != nil {
                self.state = .buffering
            }
        case .playing:
            if isPlaybackPermitted { self.state = .playing }
        @unknown default:
            break
        }
    }
    
    func player(statusDidChange status: AVPlayer.Status) {
        if (status == .failed) {
            let error = (avPlayer.error ?? item?.error) as NSError?
            playbackFailed(error: error?.code == URLError.notConnectedToInternet.rawValue
                 ? AudioPlayerError.PlaybackError.notConnectedToInternet
                 : AudioPlayerError.PlaybackError.playbackFailed
            )
        }
    }
}

extension AVPlayerWrapper: AVPlayerTimeObserverDelegate {
    
    // MARK: - AVPlayerTimeObserverDelegate
    
    func audioDidStart() {
        if isPlaybackPermitted && avPlayer.timeControlStatus == .playing && item != nil {
            state = .playing
        }
    }
    
    func timeEvent(time: CMTime) {
        delegate?.AVWrapper(secondsElapsed: time.seconds)
    }
    
}

extension AVPlayerWrapper: AVPlayerItemNotificationObserverDelegate {
    // MARK: - AVPlayerItemNotificationObserverDelegate

    func itemFailedToPlayToEndTime() {
        playbackFailed(error: AudioPlayerError.PlaybackError.playbackFailed)
    }
    
    func itemPlaybackStalled() {
        let revision = transportIntent.current.sourceRevision
        retainPlaybackForStall()
        guard transportIntent.current.sourceRevision == revision else { return }
        delegate?.AVWrapperItemPlaybackStalled()
    }
    
    func itemDidPlayToEndTime() {
        stalledSource = nil
        delegate?.AVWrapperItemDidPlayToEndTime()
    }
    
}

extension AVPlayerWrapper: AVPlayerItemObserverDelegate {
    // MARK: - AVPlayerItemObserverDelegate

    func item(statusDidChange status: AVPlayerItem.Status) {
        if status == .readyToPlay && stalledSource == nil && (state == .loading || state == .buffering) {
            state = .ready
        } else if status == .failed {
            let error = item?.error as NSError?
            playbackFailed(error: error?.code == URLError.notConnectedToInternet.rawValue
                ? .notConnectedToInternet : .playbackFailed)
        }
    }

    func item(didUpdatePlaybackLikelyToKeepUp playbackLikelyToKeepUp: Bool) {
        if stalledSource != nil {
            resumeStalledPlaybackIfReady()
        } else if playbackLikelyToKeepUp && state == .buffering {
            state = .ready
        }
    }

    func item(didUpdatePlaybackBufferEmpty playbackBufferEmpty: Bool) {
        if playbackBufferEmpty && avPlayer.timeControlStatus == .paused {
            retainPlaybackForStall(bufferEmpty: playbackBufferEmpty)
            resumeStalledPlaybackIfReady()
        } else if !playbackBufferEmpty {
            resumeStalledPlaybackIfReady()
        }
    }

    func itemDidUpdatePlaybackBufferFull() {
        resumeStalledPlaybackIfReady()
    }
        
    func item(didUpdateDuration duration: Double) {
        delegate?.AVWrapper(didUpdateDuration: duration)
    }
    
    func item(didReceiveTimedMetadata metadata: [AVTimedMetadataGroup]) {
        guard let asset = asset else { return }
        pendingTimedMetadata.append(metadata)
        prepareNextTimedMetadata(for: asset)
    }
}
