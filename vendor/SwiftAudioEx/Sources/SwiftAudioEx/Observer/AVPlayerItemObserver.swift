//
//  AVPlayerItemObserver.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 28/07/2018.
//

import Foundation
import AVFoundation

protocol AVPlayerItemObserverDelegate: AnyObject {
    func item(statusDidChange status: AVPlayerItem.Status)
    
    /**
     Called when the duration of the observed item is updated.
     */
    func item(didUpdateDuration duration: Double)
    
    /**
     Called when the playback of the observed item is or is no longer likely to keep up.
     */
    func item(didUpdatePlaybackLikelyToKeepUp playbackLikelyToKeepUp: Bool)
    func item(didUpdatePlaybackBufferEmpty playbackBufferEmpty: Bool)
    func itemDidUpdatePlaybackBufferFull()
    /**
     Called when the observed item receives metadata
     */
    func item(didReceiveTimedMetadata metadata: [AVTimedMetadataGroup])
    
}

extension AVPlayerItemObserverDelegate {
    func item(didUpdatePlaybackBufferEmpty playbackBufferEmpty: Bool) {}
    func itemDidUpdatePlaybackBufferFull() {}
}

/**
 Observing an AVPlayers status changes.
 */
class AVPlayerItemObserver: NSObject {
    
    private static var context = 0
    private let transportIntent: AVPlayerTransportIntent?
    private var currentMetadataOutput: AVPlayerItemMetadataOutput?
    
    private struct AVPlayerItemKeyPath {
        static let status = #keyPath(AVPlayerItem.status)
        static let duration = #keyPath(AVPlayerItem.duration)
        static let playbackLikelyToKeepUp = #keyPath(AVPlayerItem.isPlaybackLikelyToKeepUp)
        static let playbackBufferEmpty = #keyPath(AVPlayerItem.isPlaybackBufferEmpty)
        static let playbackBufferFull = #keyPath(AVPlayerItem.isPlaybackBufferFull)
    }
    
    private(set) var isObserving: Bool = false
    
    private(set) weak var observingItem: AVPlayerItem?
    weak var delegate: AVPlayerItemObserverDelegate?
    
    init(transportIntent: AVPlayerTransportIntent? = nil) {
        self.transportIntent = transportIntent
        super.init()
    }
    
    deinit {
        stopObservingCurrentItem()
    }
    
    /**
     Start observing an item. Will remove self as observer from old item, if any.
     
     - parameter item: The player item to observe.
     */
    func startObserving(item: AVPlayerItem) {
        stopObservingCurrentItem()
        
        self.isObserving = true
        self.observingItem = item
        item.addObserver(self, forKeyPath: AVPlayerItemKeyPath.duration, options: [.new], context: &AVPlayerItemObserver.context)
        item.addObserver(self, forKeyPath: AVPlayerItemKeyPath.playbackLikelyToKeepUp, options: [.new], context: &AVPlayerItemObserver.context)
        item.addObserver(self, forKeyPath: AVPlayerItemKeyPath.playbackBufferEmpty, options: [.new], context: &AVPlayerItemObserver.context)
        item.addObserver(self, forKeyPath: AVPlayerItemKeyPath.playbackBufferFull, options: [], context: &AVPlayerItemObserver.context)
        
        // Create and add a new metadata output to the item.
        let metadataOutput = AVPlayerItemMetadataOutput()
        metadataOutput.setDelegate(self, queue: .main)
        item.add(metadataOutput)
        self.currentMetadataOutput = metadataOutput
        item.addObserver(self, forKeyPath: AVPlayerItemKeyPath.status, options: [.new, .initial], context: &AVPlayerItemObserver.context)
    }
    
    func stopObservingCurrentItem() {
        guard let observingItem = observingItem, isObserving else {
            return
        }
        
        observingItem.removeObserver(self, forKeyPath: AVPlayerItemKeyPath.status, context: &AVPlayerItemObserver.context)
        observingItem.removeObserver(self, forKeyPath: AVPlayerItemKeyPath.duration, context: &AVPlayerItemObserver.context)
        observingItem.removeObserver(self, forKeyPath: AVPlayerItemKeyPath.playbackLikelyToKeepUp, context: &AVPlayerItemObserver.context)
        observingItem.removeObserver(self, forKeyPath: AVPlayerItemKeyPath.playbackBufferEmpty, context: &AVPlayerItemObserver.context)
        observingItem.removeObserver(self, forKeyPath: AVPlayerItemKeyPath.playbackBufferFull, context: &AVPlayerItemObserver.context)
        
        if let currentMetadataOutput = currentMetadataOutput {
            observingItem.remove(currentMetadataOutput)
        }
        
        isObserving = false
        self.observingItem = nil
        self.currentMetadataOutput = nil
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &AVPlayerItemObserver.context, let observedKeyPath = keyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        
        guard let item = object as? AVPlayerItem else { return }
        let observedIntent = transportIntent?.current
        let deliver = { [weak self, weak item] in
            guard let self = self, let item = item,
                self.isObserving, self.observingItem === item else { return }
            if observedKeyPath == AVPlayerItemKeyPath.playbackBufferEmpty
                || observedKeyPath == AVPlayerItemKeyPath.playbackBufferFull
                || observedKeyPath == AVPlayerItemKeyPath.playbackLikelyToKeepUp,
                let observedIntent = observedIntent, let currentIntent = self.transportIntent?.current {
                guard currentIntent.sourceRevision == observedIntent.sourceRevision,
                    currentIntent.commandRevision == observedIntent.commandRevision else { return }
            }
            switch observedKeyPath {
            case AVPlayerItemKeyPath.status:
                if let number = change?[.newKey] as? NSNumber,
                    let status = AVPlayerItem.Status(rawValue: number.intValue) {
                    self.delegate?.item(statusDidChange: status)
                }
            case AVPlayerItemKeyPath.duration:
                if let duration = change?[.newKey] as? CMTime {
                    self.delegate?.item(didUpdateDuration: duration.seconds)
                }
            case AVPlayerItemKeyPath.playbackBufferEmpty:
                if let bufferEmpty = change?[.newKey] as? Bool {
                    self.delegate?.item(didUpdatePlaybackBufferEmpty: bufferEmpty)
                }
            case AVPlayerItemKeyPath.playbackBufferFull:
                self.delegate?.itemDidUpdatePlaybackBufferFull()
            case AVPlayerItemKeyPath.playbackLikelyToKeepUp:
                if let likelyToKeepUp = change?[.newKey] as? Bool {
                    self.delegate?.item(didUpdatePlaybackLikelyToKeepUp: likelyToKeepUp)
                }
            default: break
            }
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }
}

extension AVPlayerItemObserver: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        if isObserving && output === currentMetadataOutput {
            delegate?.item(didReceiveTimedMetadata: groups)
        }
    }
}
