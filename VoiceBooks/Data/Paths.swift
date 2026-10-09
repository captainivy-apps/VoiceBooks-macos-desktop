import Foundation

/// Central filesystem layout. The Swift build starts fresh under its own
/// bundle-identifier directory and mirrors the Kotlin data layout beneath it.
enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.dafei.voicebook",
            isDirectory: true
        )
        createIfNeeded(dir)
        return dir
    }

    static var cacheDir: URL {
        let dir = appSupport.appendingPathComponent("cache/import_incoming", isDirectory: true)
        createIfNeeded(dir)
        return dir
    }

    static var dataRoot: URL {
        let dir = appSupport.appendingPathComponent("data", isDirectory: true)
        createIfNeeded(dir)
        return dir
    }

    static var databaseURL: URL {
        appSupport.appendingPathComponent("voicebook.db")
    }

    static var sessionFileURL: URL {
        appSupport.appendingPathComponent("playback_session.txt")
    }

    static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? appSupport
    }

    @discardableResult
    static func createIfNeeded(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}
