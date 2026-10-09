import Foundation
import Combine

/// Shared playback UI state, observable by SwiftUI. Mirrors the Kotlin
/// `PlaybackController` singleton.
final class PlaybackController: ObservableObject {
    static let shared = PlaybackController()

    @Published private(set) var state = PlaybackUiState()

    private let lock = NSLock()
    private var current = PlaybackUiState()
    private var playerScreenDismissed = false

    var immediatePauseHandler: (() -> Void)?
    var immediateResumeHandler: (() -> Void)?

    var snapshot: PlaybackUiState {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func update(_ transform: (PlaybackUiState) -> PlaybackUiState) {
        lock.lock()
        current = transform(current)
        let value = current
        lock.unlock()
        DispatchQueue.main.async { self.state = value }
    }

    func reset() {
        lock.lock()
        current = PlaybackUiState()
        let value = current
        lock.unlock()
        DispatchQueue.main.async { self.state = value }
    }

    func dismissPlayerScreen() { playerScreenDismissed = true }
    func clearPlayerScreenDismissed() { playerScreenDismissed = false }
    func isPlayerScreenDismissed() -> Bool { playerScreenDismissed }

    func requestImmediatePause() { immediatePauseHandler?() }
    func requestImmediateResume() { immediateResumeHandler?() }
}
