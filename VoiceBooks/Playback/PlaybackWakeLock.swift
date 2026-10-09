import Foundation

/// Prevents the display from sleeping during playback when the user enabled
/// "keep screen on". Desktop replacement for the Android PARTIAL_WAKE_LOCK.
final class PlaybackWakeLock {
    private var activity: NSObjectProtocol?
    private let lock = NSLock()

    func acquire() {
        lock.lock(); defer { lock.unlock() }
        guard activity == nil, AppSettings.keepScreenOn else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "VoiceBooks playback"
        )
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
