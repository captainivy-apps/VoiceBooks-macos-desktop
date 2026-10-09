import Foundation

/// Timeout policy for waiting on the audio playback head to catch up.
enum PlaybackHeadWaitPolicy {
    static let maxTimeoutMs: Int64 = 60_000
    static let minTimeoutMs: Int64 = 500
    static let slackMs: Int64 = 500
    private static let ratio: Double = 1.5

    static func expectedTimeoutMs(framesToPlay: Int64, sampleRate: Int) -> Int64 {
        guard framesToPlay > 0, sampleRate > 0 else { return minTimeoutMs }
        let audioMs = framesToPlay * 1000 / Int64(sampleRate)
        let scaled = Int64(Double(audioMs) * ratio) + slackMs
        return min(max(scaled, minTimeoutMs), maxTimeoutMs)
    }
}

/// Position helpers for a single sentence's playback progress.
enum SentencePlaybackPosition {
    static let endToleranceMs: Int64 = 100

    static func isSentencePositionAtEnd(
        _ positionMs: Int64,
        _ durationMs: Int64,
        tolerance: Int64 = endToleranceMs
    ) -> Bool {
        guard positionMs > 0, durationMs > 0 else { return false }
        return positionMs >= durationMs - tolerance
    }

    static func sanitizePositionForSentence(
        _ positionMs: Int64,
        durationMs: Int64?,
        tolerance: Int64 = endToleranceMs
    ) -> Int64 {
        if positionMs <= 0 { return 0 }
        guard let durationMs else { return positionMs }
        if durationMs <= 0 { return 0 }
        if positionMs > durationMs + tolerance { return 0 }
        return positionMs
    }
}

/// Guards pause finalization against a concurrent resume.
enum PlaybackTransitionGuards {
    static func shouldSkipPauseFinalize(
        isPlaying: Bool,
        pauseSessionAtStart: Int,
        currentSession: Int
    ) -> Bool {
        if isPlaying { return true }
        return currentSession != pauseSessionAtStart
    }
}
