//
//  QueuedAudioPlayer.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 24/03/2018.
//

import Foundation
import MediaPlayer

/**
 An audio player that can keep track of a queue of AudioItems.
 */
public class QueuedAudioPlayer: AudioPlayer, QueueManagerDelegate {
    let queue: QueueManager = QueueManager<AudioItem>()
    fileprivate var lastIndex: Int = -1
    fileprivate var lastItem: AudioItem? = nil
    private var currentItemChangeRevision: UInt = 0
    private var repeatCancellationRevision: UInt = 0

    public override init(nowPlayingInfoController: NowPlayingInfoControllerProtocol = NowPlayingInfoController(), remoteCommandController: RemoteCommandController = RemoteCommandController()) {
        super.init(nowPlayingInfoController: nowPlayingInfoController, remoteCommandController: remoteCommandController)
        queue.delegate = self
    }

    /// The repeat mode for the queue player.
    public var repeatMode: RepeatMode = .off {
        didSet {
            if oldValue != repeatMode && !repeatsCurrentItem {
                repeatCancellationRevision &+= 1
            }
        }
    }

    public override var currentItem: AudioItem? {
        queue.current
    }

    /**
     The index of the current item.
     */
    public var currentIndex: Int {
        queue.currentIndex
    }

    override public func clear() {
        let hadCurrentItem = currentIndex != -1
        queue.clearQueue()
        if !hadCurrentItem {
            super.clear()
        }
    }

    /**
     All items currently in the queue.
     */
    public var items: [AudioItem] {
        queue.items
    }

    /**
     The previous items held by the queue.
     */
    public var previousItems: [AudioItem] {
        queue.previousItems
    }

    /**
     The upcoming items in the queue.
     */
    public var nextItems: [AudioItem] {
        queue.nextItems
    }

    /**
     Will replace the current item with a new one and load it into the player.

     - parameter item: The AudioItem to replace the current item.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public override func load(item: AudioItem, playWhenReady: Bool? = nil) {
        handlePlayWhenReady(playWhenReady) {
            queue.replaceCurrentItem(with: item)
        }
    }

    /**
     Add a single item to the queue.

     - parameter item: The item to add.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public func add(item: AudioItem, playWhenReady: Bool? = nil) {
        handlePlayWhenReady(playWhenReady) {
            queue.add(item)
        }
    }

    /**
     Add items to the queue.

     - parameter items: The items to add to the queue.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public func add(items: [AudioItem], playWhenReady: Bool? = nil) {
        handlePlayWhenReady(playWhenReady) {
            queue.add(items)
        }
    }

    public func add(items: [AudioItem], at index: Int) throws {
        try queue.add(items, at: index)
        lastIndex = currentIndex
    }

    /**
     Step to the next item in the queue.
     */
    public func next() {
        let lastIndex = currentIndex
        let playbackWasActive = wrapper.playbackActive;
        _ = queue.next(wrap: repeatMode == .queue)
        if (playbackWasActive && lastIndex != currentIndex || repeatMode == .queue) {
            event.playbackEnd.emit(data: .skippedToNext)
        }
    }

    /**
     Step to the previous item in the queue.
     */
    public func previous() {
        let lastIndex = currentIndex
        let playbackWasActive = wrapper.playbackActive;
        _ = queue.previous(wrap: repeatMode == .queue)
        if (playbackWasActive && lastIndex != currentIndex || repeatMode == .queue) {
            event.playbackEnd.emit(data: .skippedToPrevious)
        }
    }

    /**
     Remove an item from the queue.

     - parameter index: The index of the item to remove.
     - throws: `AudioPlayerError.QueueError`
     */
    public func removeItem(at index: Int) throws {
        try queue.removeItem(at: index)
        lastIndex = currentIndex
    }


    /**
     Jump to a certain item in the queue.

     - parameter index: The index of the item to jump to.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     - throws: `AudioPlayerError`
     */
    public func jumpToItem(atIndex index: Int, playWhenReady: Bool? = nil) throws {
        try handlePlayWhenReady(playWhenReady) {
            if (index == currentIndex) {
                seek(to: 0)
            } else {
                _ = try queue.jump(to: index)
            }
            event.playbackEnd.emit(data: .jumpedToIndex)
        }
    }

    /**
     Move an item in the queue from one position to another.

     - parameter fromIndex: The index of the item to move.
     - parameter toIndex: The index to move the item to.
     - throws: `AudioPlayerError.QueueError`
     */
    public func moveItem(fromIndex: Int, toIndex: Int) throws {
        try queue.moveItem(fromIndex: fromIndex, toIndex: toIndex)
        lastIndex = currentIndex
    }

    /**
     Remove all upcoming items, those returned by `next()`
     */
    public func removeUpcomingItems() {
        queue.removeUpcomingItems()
    }

    /**
     Remove all previous items, those returned by `previous()`
     */
    public func removePreviousItems() {
        queue.removePreviousItems()
        lastIndex = currentIndex
    }

    private var repeatsCurrentItem: Bool {
        repeatMode == .track || (repeatMode == .queue && items.count == 1)
    }

    private func replay(repeatCancellationRevision: UInt?) {
        invalidatePendingReplay()
        let revision = playbackCommandRevision
        wrapper.seek(
            to: 0,
            shouldResumePlayback: { [weak self] in
                guard let self = self, self.playbackCommandRevision == revision else { return false }
                return repeatCancellationRevision == nil
                    || self.repeatCancellationRevision == repeatCancellationRevision
            },
            completionHandler: nil
        )
    }

    // MARK: - AVPlayerWrapperDelegate

    override func AVWrapperItemDidPlayToEndTime() {
        let revision = playbackCommandRevision
        let observedRepeatMode = repeatMode
        let observedRepeatCancellationRevision = repeatCancellationRevision
        let wasRepeatingCurrentItem = repeatsCurrentItem
        event.playbackEnd.emit(data: .playedUntilEnd)
        guard playbackCommandRevision == revision,
            repeatCancellationRevision == observedRepeatCancellationRevision else { return }
        let repeatsCurrentItem = self.repeatsCurrentItem
        guard repeatMode == observedRepeatMode || (wasRepeatingCurrentItem && repeatsCurrentItem) else { return }
        if repeatMode == .off && currentIndex == items.count - 1 {
            wrapper.state = .ended
            return
        }

        guard playWhenReady else { return }
        if repeatsCurrentItem {
            guard repeatMode == .track || wrapper.playbackActive else { return }
            replay(repeatCancellationRevision: observedRepeatCancellationRevision)
        } else {
            _ = queue.next(wrap: repeatMode == .queue)
        }
    }

    // MARK: - QueueManagerDelegate

    func onCurrentItemChanged() {
        currentItemChangeRevision &+= 1
        let revision = currentItemChangeRevision
        let item = currentItem
        let previousItem = lastItem
        let previousIndex = lastIndex
        let lastPosition = currentTime;
        if let item = item {
            super.load(item: item)
        } else {
            super.clear()
        }
        guard currentItemChangeRevision == revision else { return }
        let index = currentIndex
        lastItem = item
        lastIndex = index
        event.currentItem.emit(
            data: (
                item: item,
                index: index == -1 ? nil : index,
                lastItem: previousItem,
                lastIndex: previousIndex == -1 ? nil : previousIndex,
                lastPosition: lastPosition
            )
        )
    }

    func onSkippedToSameCurrentItem() {
        if (wrapper.playbackActive) {
            replay(repeatCancellationRevision: nil)
        }
    }
}
