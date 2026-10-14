import Foundation

struct AudioSessionPlaybackError: LocalizedError {
    let code: String
    let underlyingError: Error?

    var errorDescription: String? {
        underlyingError?.localizedDescription
            ?? "Playback requires an explicit Play command after media services reset."
    }
}

final class AudioSessionPlaybackActivation {
    private enum State {
        case inactive
        case active
        case requiresExplicitPlay
    }

    private var state: State = .inactive
    private let revisionLock = NSLock()
    private var resetRevision: UInt64 = 0
    private let activateSession: () throws -> Void
    private let deactivateSession: () throws -> Void

    init(
        activateSession: @escaping () throws -> Void, deactivateSession: @escaping () throws -> Void
    ) {
        self.activateSession = activateSession
        self.deactivateSession = deactivateSession
    }

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    var requiresExplicitPlay: Bool {
        if case .requiresExplicitPlay = state { return true }
        return false
    }

    func invalidateForInterruption() {
        if !requiresExplicitPlay { state = .inactive }
    }

    func mediaServicesWereReset() {
        revisionLock.lock()
        resetRevision += 1
        revisionLock.unlock()
        state = .requiresExplicitPlay
    }

    func captureResetRevision() -> UInt64 {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        return resetRevision
    }

    func requireCurrentResetRevision(_ revision: UInt64) throws {
        guard revision == captureResetRevision() else {
            throw AudioSessionPlaybackError(
                code: "ios_audio_session_requires_explicit_play", underlyingError: nil)
        }
    }

    func configure(_ configureSession: () throws -> Void) throws {
        do {
            try configureSession()
        } catch {
            throw AudioSessionPlaybackError(
                code: "audio_session_configuration_failed", underlyingError: error)
        }
    }

    func activate(userInitiated: Bool, configureSession: () throws -> Void) throws {
        if requiresExplicitPlay && !userInitiated {
            throw AudioSessionPlaybackError(
                code: "ios_audio_session_requires_explicit_play", underlyingError: nil)
        }
        do {
            try configure(configureSession)
            do {
                try activateSession()
            } catch {
                throw AudioSessionPlaybackError(
                    code: "audio_session_activation_failed", underlyingError: error)
            }
            state = .active
        } catch {
            if !requiresExplicitPlay { state = .inactive }
            throw error
        }
    }

    func deactivate() throws {
        do {
            try deactivateSession()
            if !requiresExplicitPlay { state = .inactive }
        } catch {
            throw AudioSessionPlaybackError(
                code: "audio_session_deactivation_failed", underlyingError: error)
        }
    }
}
