import Foundation

/// Persists the active playback session across app restarts.
/// File format: line 0 = bookId, line 1 = shouldResumeOnRestart.
final class PlaybackSessionStore {
    struct Session {
        let bookId: String
        let shouldResumeOnRestart: Bool
    }

    private let fileURL: URL

    init(rootDir: URL) {
        self.fileURL = rootDir.appendingPathComponent("playback_session.txt")
    }

    func save(bookId: String, shouldResumeOnRestart: Bool) {
        guard !bookId.isEmpty else { return }
        try? "\(bookId)\n\(shouldResumeOnRestart)".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func load() -> Session? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n")
        guard let first = lines.first, !first.isEmpty else { return nil }
        let resume = lines.count > 1 ? (lines[1] as NSString).boolValue : false
        return Session(bookId: first, shouldResumeOnRestart: resume)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
