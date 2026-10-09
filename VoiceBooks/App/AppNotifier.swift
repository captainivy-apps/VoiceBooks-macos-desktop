import Foundation
import Combine

struct AppNotification: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let long: Bool
}

/// Transient user messages (replaces the Android Toast / Kotlin AppNotifier).
final class AppNotifier: ObservableObject {
    static let shared = AppNotifier()

    @Published private(set) var current: AppNotification?

    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, long: Bool = false) {
        let notification = AppNotification(message: message, long: long)
        DispatchQueue.main.async {
            self.current = notification
            self.dismissTask?.cancel()
            self.dismissTask = Task { [weak self] in
                let seconds: Double = long ? 3.0 : 2.0
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { return }
                self?.current = nil
            }
        }
    }
}
