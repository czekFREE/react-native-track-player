//
//  Event.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 09/03/2019.
//

import Foundation
import MediaPlayer

extension AudioPlayer {
    
    public typealias PlayWhenReadyChangeData = Bool
    public typealias StateChangeEventData = AudioPlayerState
    public typealias PlaybackEndEventData = PlaybackEndedReason
    public typealias SecondElapseEventData = TimeInterval
    public typealias FailEventData = Error?
    public typealias SeekEventData = (seconds: Double, didFinish: Bool)
    public typealias UpdateDurationEventData = Double
    public typealias MetadataCommonEventData = [AVMetadataItem]
    public typealias MetadataTimedEventData = [AVTimedMetadataGroup]
    public typealias DidRecreateAVPlayerEventData = ()
    public typealias CurrentItemEventData = (
        item: AudioItem?,
        index: Int?,
        lastItem: AudioItem?,
        lastIndex: Int?,
        lastPosition: Double?
    )
    
    public struct EventHolder {
        
        /**
         Emitted when the `AudioPlayer`s state is changed
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         */
        public let stateChange: AudioPlayer.Event<StateChangeEventData> = AudioPlayer.Event()

        /**
         Emitted when the `AudioPlayer#playWhenReady` has changed
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         */
        public let playWhenReadyChange: AudioPlayer.Event<PlayWhenReadyChangeData> = AudioPlayer.Event()
        
        /**
         Emitted when the playback of the player, for some reason, has stopped.
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         */
        public let playbackEnd: AudioPlayer.Event<PlaybackEndEventData> = AudioPlayer.Event()
        
        /**
         Emitted when a second is elapsed in the `AudioPlayer`.
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         */
        public let secondElapse: AudioPlayer.Event<SecondElapseEventData> = AudioPlayer.Event()
        
        /**
         Emitted when the player encounters an error. This will ultimately result in the AVPlayer instance to be recreated.
         If this event is emitted, it means you will need to load a new item in some way. Calling play() will not resume playback.
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         */
        public let fail: AudioPlayer.Event<FailEventData> = AudioPlayer.Event()
        
        /**
         Emitted when the player is done attempting to seek.
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         */
        public let seek: AudioPlayer.Event<SeekEventData> = AudioPlayer.Event()
        
        /**
         Emitted when the player updates its duration.
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         */
        public let updateDuration: AudioPlayer.Event<UpdateDurationEventData> = AudioPlayer.Event()

        /**
         Emitted when the player receives common metadata.
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         */
        public let receiveCommonMetadata: AudioPlayer.Event<MetadataCommonEventData> = AudioPlayer.Event()
        
        /**
         Emitted when the player receives timed metadata.
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         */
        public let receiveTimedMetadata: AudioPlayer.Event<MetadataTimedEventData> = AudioPlayer.Event()
        
        /**
         Emitted when the player receives chapter metadata.
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         */
        public let receiveChapterMetadata: AudioPlayer.Event<MetadataTimedEventData> = AudioPlayer.Event()
        
        /**
         Emitted when the underlying AVPlayer instance is recreated. Recreation happens if the current player fails.
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         - Note: It can be necessary to set the AVAudioSession's category again when this event is emitted.
         */
        public let didRecreateAVPlayer: AudioPlayer.Event<()> = AudioPlayer.Event()

        /**
         Emitted when the current track has changed.
         - Important: Remember to dispatch to the main queue if any UI is updated in the event handler.
         - Note: It is only fired for instances of a QueuedAudioPlayer.
         */
        public let currentItem: AudioPlayer.Event<CurrentItemEventData> = AudioPlayer.Event()
    }
    
    public typealias EventClosure<EventData> = (EventData) -> Void
    
    class Invoker<EventData> {
        
        let invoke: EventClosure<EventData>
        weak var listener: AnyObject?
        let onMainQueue: Bool
        
        init<Listener: AnyObject>(listener: Listener, onMainQueue: Bool, closure: @escaping EventClosure<EventData>) {
            self.listener = listener
            self.onMainQueue = onMainQueue
            invoke = { [weak listener] (data: EventData) in
                guard let _ = listener else {
                    return
                }
                closure(data)
            }
        }
        
    }
    
    public class Event<EventData> {
        private let queue: DispatchQueue = DispatchQueue(label: "com.swiftAudioEx.eventQueue")
        private let listenerLock = NSLock()
        private var invokers: [Invoker<EventData>] = []
        private var pendingMainDeliveries: [() -> Void] = []
        private var isDeliveringMainEvents = false
        
        public func addListener<Listener: AnyObject>(_ listener: Listener, _ closure: @escaping EventClosure<EventData>) {
            addListener(listener, onMainQueue: false, closure)
        }

        public func addListener<Listener: AnyObject>(_ listener: Listener, onMainQueue: Bool, _ closure: @escaping EventClosure<EventData>) {
            listenerLock.lock()
            invokers.append(Invoker(listener: listener, onMainQueue: onMainQueue, closure: closure))
            listenerLock.unlock()
        }
        
        public func removeListener(_ listener: AnyObject) {
            listenerLock.lock()
            let previousInvokers = invokers
            invokers = previousInvokers.filter { $0.listener !== listener }
            listenerLock.unlock()
            withExtendedLifetime(previousInvokers) {}
        }
        
        func emit(data: EventData) {
            listenerLock.lock()
            let previousInvokers = invokers
            let currentInvokers = previousInvokers.filter { $0.listener != nil }
            invokers = currentInvokers
            let mainInvokers = currentInvokers.filter { $0.onMainQueue }
            if !mainInvokers.isEmpty {
                pendingMainDeliveries.append {
                    for invoker in mainInvokers { invoker.invoke(data) }
                }
            }
            listenerLock.unlock()
            withExtendedLifetime(previousInvokers) {}

            let asynchronousInvokers = currentInvokers.filter { !$0.onMainQueue }
            if !asynchronousInvokers.isEmpty {
                queue.async {
                    for invoker in asynchronousInvokers { invoker.invoke(data) }
                }
            }

            guard !mainInvokers.isEmpty else { return }
            if Thread.isMainThread {
                deliverPendingMainEvents()
            } else {
                DispatchQueue.main.async { self.deliverPendingMainEvents() }
            }
        }

        private func deliverPendingMainEvents() {
            guard !isDeliveringMainEvents else { return }
            isDeliveringMainEvents = true
            defer { isDeliveringMainEvents = false }

            while true {
                listenerLock.lock()
                let deliveries = pendingMainDeliveries
                pendingMainDeliveries.removeAll()
                listenerLock.unlock()

                guard !deliveries.isEmpty else { return }
                for deliver in deliveries { deliver() }
            }
        }
    }
    
}
