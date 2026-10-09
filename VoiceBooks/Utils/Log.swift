import Foundation
import os.log

enum Log {
    private static let logger = Logger(subsystem: "com.dafei.voicebook", category: "app")

    static func debug(_ tag: String, _ message: String) {
        logger.debug("[\(tag, privacy: .public)] \(message, privacy: .public)")
    }

    static func info(_ tag: String, _ message: String) {
        logger.info("[\(tag, privacy: .public)] \(message, privacy: .public)")
    }

    static func warn(_ tag: String, _ message: String) {
        logger.warning("[\(tag, privacy: .public)] \(message, privacy: .public)")
    }

    static func error(_ tag: String, _ message: String, _ error: Error? = nil) {
        if let error {
            logger.error("[\(tag, privacy: .public)] \(message, privacy: .public) — \(String(describing: error), privacy: .public)")
        } else {
            logger.error("[\(tag, privacy: .public)] \(message, privacy: .public)")
        }
    }
}
