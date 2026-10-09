import Foundation
import Combine

enum EngineSwitchState {
    case idle
    case previewing
    case applying
    case failed
}

enum TtsPreviewOutcome {
    case success(TtsModelBenchmark)
    case failure(String)
    case cancelled
}

/// Shared gate that blocks navigation while the TTS engine is being switched.
final class TtsSettingsGate: ObservableObject {
    @Published private(set) var isBlocking = false

    func setBlocking(_ blocking: Bool) {
        DispatchQueue.main.async { self.isBlocking = blocking }
    }
}
