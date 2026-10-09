import Foundation

enum StartupIssueCategory {
    case library
    case general
}

struct StartupIssue {
    let category: StartupIssueCategory
    let userMessage: String
    let debugMessage: String?
    let error: Error?

    var isLibraryIssue: Bool { category == .library }
}

enum StartupIssueClassifier {
    static let libraryMessage = "检测到书库数据异常，请前往设置页重建书库。"
    static let generalMessage = "启动时发生异常，请稍后重试。"

    static func classify(_ error: Error) -> StartupIssue {
        let library = isLibraryIssue(error)
        return StartupIssue(
            category: library ? .library : .general,
            userMessage: library ? libraryMessage : generalMessage,
            debugMessage: (error as NSError).localizedDescription,
            error: error
        )
    }

    static func isLibraryIssue(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            let className = String(describing: type(of: e))
            let desc = (e.localizedDescription + " " + e.domain + " " + String(describing: e.userInfo)).lowercased()
            if className.lowercased().contains("sqlite") { return true }
            if desc.contains("books")
                || desc.contains("voicebook.db")
                || desc.contains("migration")
                || desc.contains("no such table")
                || desc.contains("contentmd5") {
                return true
            }
            // An I/O failure originating from book storage is treated as a library issue.
            if e.domain == NSPOSIXErrorDomain || e.domain == NSCocoaErrorDomain {
                return true
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
