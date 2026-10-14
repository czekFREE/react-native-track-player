import Foundation

final class PlaybackOwnerGeneration {
    private(set) var isCurrent = true

    func invalidate() {
        isCurrent = false
    }

    func performOnMainIfCurrent(_ action: @escaping () -> Void) {
        let perform = { [weak self] in
            guard self?.isCurrent == true else { return }
            action()
        }
        if Thread.isMainThread {
            perform()
        } else {
            DispatchQueue.main.async(execute: perform)
        }
    }
}
