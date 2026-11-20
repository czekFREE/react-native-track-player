//
//  AudioPlayerTimeEventObserver.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 09/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation

protocol AVPlayerTimeObserverDelegate: AnyObject {
    func audioDidStart()
    func timeEvent(time: CMTime)
}

/**
 Class for observing time-based events from the AVPlayer
 */
class AVPlayerTimeObserver {
    
    /// The time to use as start boundary time. Cannot be zero.
    private static let startBoundaryTime: CMTime = CMTime(value: 1, timescale: 1000)
    
    private var boundaryRevision = UUID()
    private var periodicRevision = UUID()
    var boundaryTimeStartObserverToken: Any?
    var periodicTimeObserverToken: Any?
    
    weak var player: AVPlayer? {
        willSet {
            unregisterForBoundaryTimeEvents()
            unregisterForPeriodicEvents()
        }
    }
    
    /// The frequence to receive periodic time events.
    /// Setting this to a new value will trigger a re-registering to the periodic events of the player.
    var periodicObserverTimeInterval: CMTime {
        didSet {
            if oldValue != periodicObserverTimeInterval {
                registerForPeriodicTimeEvents()
            }
        }
    }
    
    weak var delegate: AVPlayerTimeObserverDelegate?
    
    init(periodicObserverTimeInterval: CMTime) {
        self.periodicObserverTimeInterval = periodicObserverTimeInterval
    }
    
    deinit {
        unregisterForPeriodicEvents()
        unregisterForBoundaryTimeEvents()
    }
    
    /**
     Will register for the AVPlayer BoundaryTimeEvents, to trigger start and complete events.
     */
    func registerForBoundaryTimeEvents() {
        guard let player = player else {
            return
        }
        unregisterForBoundaryTimeEvents()
        let revision = boundaryRevision
        let item = player.currentItem
        boundaryTimeStartObserverToken = player.addBoundaryTimeObserver(
            forTimes: [AVPlayerTimeObserver.startBoundaryTime].map({
                NSValue(time: $0)
            }),
            queue: .main,
            using: { [weak self, weak player] in
                guard let self = self, let player = player,
                    self.player === player, self.boundaryRevision == revision,
                    item != nil, player.currentItem === item else { return }
                self.delegate?.audioDidStart()
            }
        )
    }
    
    /**
     Unregister from the boundary events of the player.
     */
    func unregisterForBoundaryTimeEvents() {
        boundaryRevision = UUID()
        guard
            let player = player,
            let boundaryTimeStartObserverToken = boundaryTimeStartObserverToken
        else { return }
        player.removeTimeObserver(boundaryTimeStartObserverToken)
        self.boundaryTimeStartObserverToken = nil
    }
    
    /**
     Start observing periodic time events.
     Will trigger unregisterForPeriodicEvents() first to avoid multiple subscriptions.
     */
    func registerForPeriodicTimeEvents() {
        guard let player = player else {
            return
        }
        unregisterForPeriodicEvents()
        let revision = periodicRevision
        let item = player.currentItem
        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: periodicObserverTimeInterval, queue: .main
        ) { [weak self, weak player] time in
            guard let self = self, let player = player,
                self.player === player, self.periodicRevision == revision,
                item != nil, player.currentItem === item else { return }
            self.delegate?.timeEvent(time: time)
        }
    }
    
    /**
     Unregister for periodic events.
     */
    func unregisterForPeriodicEvents() {
        periodicRevision = UUID()
        guard let player = player, let periodicTimeObserverToken = periodicTimeObserverToken else {
            return
        }
        player.removeTimeObserver(periodicTimeObserverToken)
        self.periodicTimeObserverToken = nil
    }
    
}
