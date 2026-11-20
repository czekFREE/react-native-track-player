//
//  AudioPlayerObserver.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 09/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation

final class AVPlayerEventRevision {
    private let lock = NSLock()
    private var value = UUID()

    var current: UUID {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance() {
        lock.lock()
        value = UUID()
        lock.unlock()
    }
}

final class AVPlayerTransportIntent {
    struct Snapshot {
        var sourceRevision = UUID()
        var commandRevision = UUID()
        var playWhenReady = false
        var automaticallyPausesOnRouteLoss = true
        var itemIdentifier: ObjectIdentifier?
        var hasAcceptedPlayback = false

        func accepts(_ status: AVPlayer.TimeControlStatus, observed: Snapshot) -> Bool {
            guard sourceRevision == observed.sourceRevision else { return false }
            if commandRevision == observed.commandRevision { return true }
            switch status {
            case .paused: return !playWhenReady
            case .playing, .waitingToPlayAtSpecifiedRate: return playWhenReady
            @unknown default: return false
            }
        }
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var hostPlaybackPermission: (() -> Bool)?

    var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    var playbackPermission: (() -> Bool)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return hostPlaybackPermission
        }
        set {
            lock.lock()
            let previous = hostPlaybackPermission
            hostPlaybackPermission = newValue
            lock.unlock()
            withExtendedLifetime(previous) {}
        }
    }

    func update(playWhenReady: Bool) {
        lock.lock()
        snapshot.commandRevision = UUID()
        snapshot.playWhenReady = playWhenReady
        lock.unlock()
    }

    func setAutomaticallyPausesOnRouteLoss(_ enabled: Bool) {
        lock.lock()
        snapshot.automaticallyPausesOnRouteLoss = enabled
        lock.unlock()
    }

    func retireSource() {
        lock.lock()
        snapshot.sourceRevision = UUID()
        snapshot.itemIdentifier = nil
        snapshot.hasAcceptedPlayback = false
        lock.unlock()
    }

    func bind(item: AVPlayerItem) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        snapshot.itemIdentifier = ObjectIdentifier(item)
        snapshot.hasAcceptedPlayback = false
        return snapshot
    }

    func recordPlaybackAcceptance(
        status: AVPlayer.TimeControlStatus, item: AVPlayerItem?, observed: Snapshot
    ) {
        guard status == .waitingToPlayAtSpecifiedRate || status == .playing,
            let item = item else { return }
        let itemIdentifier = ObjectIdentifier(item)
        lock.lock()
        defer { lock.unlock() }
        guard snapshot.sourceRevision == observed.sourceRevision,
            snapshot.itemIdentifier == itemIdentifier,
            observed.itemIdentifier == itemIdentifier else { return }
        snapshot.hasAcceptedPlayback = true
    }
}

protocol AVPlayerObserverDelegate: AnyObject {
    
    /**
     Called when the AVPlayer.status changes.
     */
    func player(statusDidChange status: AVPlayer.Status)
    
    /**
     Called when the AVPlayer.timeControlStatus changes.
     */
    func player(didChangeTimeControlStatus status: AVPlayer.TimeControlStatus)
}

/**
 Observing an AVPlayers status changes.
 */
class AVPlayerObserver: NSObject {

    private static var context = 0
    private let transportIntent: AVPlayerTransportIntent

    private struct AVPlayerKeyPath {
        static let status = #keyPath(AVPlayer.status)
        static let timeControlStatus = #keyPath(AVPlayer.timeControlStatus)
    }

    private let statusChangeOptions: NSKeyValueObservingOptions = [.new, .initial]
    private let timeControlStatusChangeOptions: NSKeyValueObservingOptions = [.new]
    private(set) var isObserving: Bool = false

    weak var delegate: AVPlayerObserverDelegate?
    weak var player: AVPlayer? {
        willSet {
            stopObserving()
        }
    }

    init(transportIntent: AVPlayerTransportIntent = AVPlayerTransportIntent()) {
        self.transportIntent = transportIntent
        super.init()
    }

    deinit {
        stopObserving()
    }

    /**
     Start receiving events from this observer.
     */
    func startObserving() {
        if (isObserving) { return };
        guard let player = player else {
            return
        }
        isObserving = true
        player.addObserver(
            self,
            forKeyPath: AVPlayerKeyPath.timeControlStatus,
            options: timeControlStatusChangeOptions,
            context: &AVPlayerObserver.context
        )
        player.addObserver(
            self,
            forKeyPath: AVPlayerKeyPath.status,
            options: statusChangeOptions,
            context: &AVPlayerObserver.context
        )
    }

    func stopObserving() {
        guard let player = player, isObserving else {
            return
        }
        player.removeObserver(self, forKeyPath: AVPlayerKeyPath.status, context: &AVPlayerObserver.context)
        player.removeObserver(self, forKeyPath: AVPlayerKeyPath.timeControlStatus, context: &AVPlayerObserver.context)
        isObserving = false
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &AVPlayerObserver.context, let observedKeyPath = keyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        guard let observedPlayer = object as? AVPlayer else { return }
        let observedIntent = transportIntent.current
        let item = observedPlayer.currentItem
        if observedKeyPath == AVPlayerKeyPath.timeControlStatus,
            let number = change?[.newKey] as? NSNumber,
            let status = AVPlayer.TimeControlStatus(rawValue: number.intValue) {
            transportIntent.recordPlaybackAcceptance(
                status: status, item: item, observed: observedIntent
            )
        }
        let deliver = { [weak self, weak observedPlayer] in
            guard let self = self, let observedPlayer = observedPlayer, self.isObserving,
                self.player === observedPlayer, observedPlayer.currentItem === item
            else { return }
            switch observedKeyPath {
            case AVPlayerKeyPath.status:
                if let number = change?[.newKey] as? NSNumber,
                    let status = AVPlayer.Status(rawValue: number.intValue) {
                    self.delegate?.player(statusDidChange: status)
                }
            case AVPlayerKeyPath.timeControlStatus:
                if let number = change?[.newKey] as? NSNumber,
                    let status = AVPlayer.TimeControlStatus(rawValue: number.intValue),
                    self.transportIntent.current.accepts(status, observed: observedIntent),
                    (status != .paused || observedPlayer.rate == 0),
                    observedPlayer.timeControlStatus == status {
                    self.delegate?.player(didChangeTimeControlStatus: status)
                }
            default: break
            }
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }
}
