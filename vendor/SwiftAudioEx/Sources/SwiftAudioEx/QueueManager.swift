//
//  QueueManager.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 24/03/2018.
//

import Foundation

protocol QueueManagerDelegate: AnyObject {
    func onCurrentItemChanged()
    func onSkippedToSameCurrentItem()
}

class QueueManager<T> {

    fileprivate let recursiveLock = NSRecursiveLock()

    fileprivate func synchronizeThrows<T>(action: () throws -> T) throws -> T {
        recursiveLock.lock()
        defer { recursiveLock.unlock() }
        return try action()
    }

    fileprivate func synchronize <T>(action: () -> T) -> T {
        recursiveLock.lock()
        defer { recursiveLock.unlock() }
        return action()
    }
    
    weak var delegate: QueueManagerDelegate? = nil

    private var _currentIndex: Int = -1
    private var _items: [T] = []
    /**
     The index of the current item. `-1` when there is no current item
     */
    private(set) var currentIndex: Int {
        get {
            return synchronize {
                return _currentIndex
            }
        }

        set {
            return synchronize {
                self._currentIndex = newValue
            }
        }
    }

    /**
     All items held by the queue.
     */
    var items: [T] {
        return synchronize { _items }
    }

    public var nextItems: [T] {
        return synchronize {
            return currentIndex == -1 || currentIndex == items.count - 1
                ? []
                : Array(items[currentIndex + 1..<items.count])
        }
    }

    public var previousItems: [T] {
        return synchronize {
            return currentIndex <= 0
            ? []
            : Array(items[0..<currentIndex])
        }
    }

    /**
     The current item for the queue.
     */
    public var current: T? {
        return synchronize {
            return 0 <= _currentIndex && _currentIndex < items.count ? items[_currentIndex] : nil
        }
    }

    private func throwIfQueueEmpty() throws {
        if items.count == 0 {
            throw AudioPlayerError.QueueError.empty
        }
    }

    private func throwIfIndexInvalid(
        index: Int,
        name: String = "index",
        min: Int? = nil,
        max: Int? = nil
    ) throws {
        guard index >= (min ?? 0) && (max ?? items.count) > index else {
            throw AudioPlayerError.QueueError.invalidIndex(
                index: index,
                message: "\(name.prefix(1).uppercased() + name.dropFirst())) has to be positive and smaller than the count of current items (\(items.count))"
            )
        }
    }

    /**
     Add a single item to the queue.

     - parameter item: The `AudioItem` to be added.
     */
    public func add(_ item: T) {
        add([item])
    }

    /**
     Add an array of items to the queue.

     - parameter items: The `AudioItem`s to be added.
     */
    public func add(_ items: [T]) {
        guard !items.isEmpty else { return }
        let currentItemChanged = synchronize {
            let wasEmpty = _items.isEmpty
            _items.append(contentsOf: items)
            if wasEmpty { _currentIndex = 0 }
            return wasEmpty
        }
        if currentItemChanged {
            delegate?.onCurrentItemChanged()
        }
    }

    /**
     Add an array of items to the queue at a given index.

     - parameter items: The `AudioItem`s to be added.
     - parameter at: The index to insert the items at.
     */
    public func add(_ items: [T], at index: Int) throws {
        guard !items.isEmpty else { return }
        let currentItemChanged = try synchronizeThrows {
            guard index >= 0 && _items.count >= index else {
                throw AudioPlayerError.QueueError.invalidIndex(
                    index: index,
                    message:
                        "Index to insert at has to be non-negative and equal to or smaller than the number of items: (\(items.count))"
                )
            }
            let wasEmpty = _items.isEmpty
            _items.insert(contentsOf: items, at: index)
            if wasEmpty {
                _currentIndex = 0
            } else if _currentIndex >= index {
                _currentIndex += items.count
            }
            return wasEmpty
        }
        if currentItemChanged {
            delegate?.onCurrentItemChanged()
        }
    }

    internal enum SkipDirection : Int {
        case next = 1
        case previous = -1
    }

    private func skip(direction: SkipDirection, wrap: Bool) -> T? {
        var skippedToSameCurrentItem = false
        var currentItemChanged = false
        synchronize {
            let count = _items.count
            if (current == nil || count == 0) {
                return
            }
            if (count == 1) {
                skippedToSameCurrentItem = wrap
            } else {
                var index = currentIndex + direction.rawValue
                if (wrap) {
                    index = (count + index) % count
                }
                let oldIndex = currentIndex
                currentIndex = max(0, min(count - 1, index))
                currentItemChanged = oldIndex != currentIndex
            }
        }
        if skippedToSameCurrentItem {
            delegate?.onSkippedToSameCurrentItem()
        }
        if currentItemChanged {
            delegate?.onCurrentItemChanged()
        }
        return current
    }

    /**
     Makes the next item in the queue active, or the last item when already at the end of the queue. When wrap is true and at the end of the queue, the first track in the queue is made active.
     - parameter wrap: Whether to wrap to the start of the queue
     - returns: The next (or current) item.
     */
    @discardableResult
    public func next(wrap: Bool = false) -> T? {
        return skip(direction: SkipDirection.next, wrap: wrap)
    }

    /**
     Makes the previous item in the queue active, or the first item when already at the start of the queue. When wrap is true and at the start of the queue, the last track in the queue is made active.

     - parameter wrap: Whether to wrap to the end of the queue
     - returns: The previous item.
     */
    @discardableResult
    public func previous(wrap: Bool = false) -> T? {
        return skip(direction: SkipDirection.previous, wrap: wrap)
    }

    /**
     Jump to a position in the queue.
     Will update the current item.

     - parameter index: The index to jump to.
     - throws: `AudioPlayerError.QueueError`
     - returns: The item at the index.
     */
    @discardableResult
    public func jump(to index: Int) throws -> T {
        var skippedToSameCurrentItem = false
        var currentItemChanged = false
        let result = try synchronizeThrows {
            try throwIfQueueEmpty();
            try throwIfIndexInvalid(index: index)
            
            if (index == currentIndex) {
                skippedToSameCurrentItem = true
            } else {
                currentIndex = index
                currentItemChanged = true
            }
            return current!
        }
        if (skippedToSameCurrentItem) {
            delegate?.onSkippedToSameCurrentItem()
        }
        if (currentItemChanged) {
            delegate?.onCurrentItemChanged()
        }
        return result
    }

    /**
     Move an item in the queue.

     - parameter fromIndex: The index of the item to be moved.
     - parameter toIndex: The index to move the item to. If the index is larger than the size of the queue, the item is moved to the end of the queue instead.
     - throws: `AudioPlayerError.QueueError`
     */
    public func moveItem(fromIndex: Int, toIndex: Int) throws {
        try synchronizeThrows {
            try throwIfQueueEmpty();
            try throwIfIndexInvalid(index: fromIndex, name: "fromIndex")
            guard toIndex >= 0 else {
                throw AudioPlayerError.QueueError.invalidIndex(index: toIndex, message: "toIndex has to be non-negative")
            }
            
            let item = _items.remove(at: fromIndex)
            let destinationIndex = min(_items.count, toIndex)
            _items.insert(item, at: destinationIndex)
            if (fromIndex == currentIndex) {
                currentIndex = destinationIndex
            } else if fromIndex < currentIndex && destinationIndex >= currentIndex {
                currentIndex -= 1
            } else if fromIndex > currentIndex && destinationIndex <= currentIndex {
                currentIndex += 1
            }
        }
    }

    /**
     Remove an item.

     - parameter index: The index of the item to remove.
     - throws: AudioPlayerError.QueueError
     - returns: The removed item.
     */
    public func removeItem(at index: Int) throws -> T {
        var currentItemChanged = false
        let result = try synchronizeThrows {
            try throwIfQueueEmpty()
            try throwIfIndexInvalid(index: index)
            let result = _items.remove(at: index)
            if index == currentIndex {
                currentIndex = items.count > 0 ? currentIndex % items.count : -1
                currentItemChanged = true
            } else if index < currentIndex {
                currentIndex -= 1
            }
            
            return result;
        }
        if (currentItemChanged) {
            delegate?.onCurrentItemChanged()
        }
        return result
    }

    /**
     Replace the current item with a new one or select it as the first item in an empty queue.

     - parameter item: The item to set as the new current item.
     */
    public func replaceCurrentItem(with item: T) {
        synchronize {
            if _items.isEmpty {
                _items.append(item)
                _currentIndex = 0
            } else {
                _items[_currentIndex] = item
            }
        }
        delegate?.onCurrentItemChanged()
    }

    /**
     Remove all previous items in the queue.
     If no previous items exist, no action will be taken.
     */
    public func removePreviousItems() {
        synchronize {
            if (items.count == 0) { return };
            guard currentIndex > 0 else { return }
            _items.removeSubrange(0..<currentIndex)
            currentIndex = 0
        }
    }

    /**
     Remove upcoming items.
     If no upcoming items exist, no action will be taken.
     */
    public func removeUpcomingItems() {
        synchronize {
            if (items.count == 0) { return };
            let nextIndex = currentIndex + 1
            guard nextIndex < items.count else { return }
            _items.removeSubrange(nextIndex..<_items.count)
        }
    }

    /**
     Removes all items for queue
     */
    public func clearQueue() {
        var currentItemChanged = false
        synchronize {
            let itemWasNil = currentIndex == -1;
            currentIndex = -1
            _items.removeAll()
            currentItemChanged = !itemWasNil
        }
        if (currentItemChanged) {
            delegate?.onCurrentItemChanged()
        }
    }

}
