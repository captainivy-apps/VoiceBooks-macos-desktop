import Foundation

/// UserDefaults-backed settings namespace, mirroring the Datastore keys used by
/// the Kotlin desktop build. View models mirror values into `@Published` fields.
enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    enum Key {
        static let keepScreenOn = "keep_screen_on"
        static let defaultTtsEngine = "default_tts_engine"
        static let defaultVoice = "default_voice"
        static let sortBy = "sort_by"
        static let sortOrder = "sort_order"
        static let playbackSpeed = "playback_speed"
        static let sleepTimerMinutes = "sleep_timer_minutes"
        static let sleepUntilEnd = "sleep_until_end"
        static let ttsPreviewText = "tts_preview_text"
        static let subtitleFontSize = "subtitle_font_size"
    }

    static var keepScreenOn: Bool {
        get { defaults.object(forKey: Key.keepScreenOn) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.keepScreenOn) }
    }

    static var defaultTtsEngine: String {
        get { defaults.string(forKey: Key.defaultTtsEngine) ?? "" }
        set { defaults.set(newValue, forKey: Key.defaultTtsEngine) }
    }

    static var defaultVoice: String {
        get { defaults.string(forKey: Key.defaultVoice) ?? "" }
        set { defaults.set(newValue, forKey: Key.defaultVoice) }
    }

    static var sortBy: SortBy {
        get {
            guard let raw = defaults.string(forKey: Key.sortBy),
                  let value = SortBy(rawValue: raw) else { return .lastPlayed }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Key.sortBy) }
    }

    static var sortOrder: SortOrder {
        get {
            guard let raw = defaults.string(forKey: Key.sortOrder),
                  let value = SortOrder(rawValue: raw) else { return .desc }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Key.sortOrder) }
    }

    static var playbackSpeed: Float {
        get {
            if defaults.object(forKey: Key.playbackSpeed) == nil { return 1.0 }
            return defaults.float(forKey: Key.playbackSpeed)
        }
        set { defaults.set(newValue, forKey: Key.playbackSpeed) }
    }

    static var sleepTimerMinutes: Int {
        get { defaults.integer(forKey: Key.sleepTimerMinutes) }
        set { defaults.set(newValue, forKey: Key.sleepTimerMinutes) }
    }

    static var sleepUntilEnd: Bool {
        get { defaults.bool(forKey: Key.sleepUntilEnd) }
        set { defaults.set(newValue, forKey: Key.sleepUntilEnd) }
    }

    static var ttsPreviewText: String {
        get { defaults.string(forKey: Key.ttsPreviewText) ?? "" }
        set { defaults.set(newValue, forKey: Key.ttsPreviewText) }
    }

    /// User-adjusted subtitle font size (points). `nil` means the user never
    /// adjusted it, so callers fall back to their own default.
    static var subtitleFontSize: Double? {
        get {
            guard defaults.object(forKey: Key.subtitleFontSize) != nil else { return nil }
            return defaults.double(forKey: Key.subtitleFontSize)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.subtitleFontSize)
            } else {
                defaults.removeObject(forKey: Key.subtitleFontSize)
            }
        }
    }

    static func clearSleepTimer() {
        sleepTimerMinutes = 0
        sleepUntilEnd = false
    }

    static func setSleepTimer(minutes: Int, untilEnd: Bool) {
        sleepTimerMinutes = minutes
        sleepUntilEnd = untilEnd
    }
}
