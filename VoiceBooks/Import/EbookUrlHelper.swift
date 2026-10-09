import Foundation

enum EbookUrlHelper {
    static let supportedExtension = "epub"
    private static let supportedExtensions: Set<String> = [supportedExtension]

    static func isValidHttpUrl(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    static func isSupportedExtension(_ ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }

    static func extensionOf(_ fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: ".") else { return "" }
        return String(fileName[fileName.index(after: dot)...]).lowercased()
    }

    static func extensionFromUrl(_ url: String) -> String? {
        let fileName = fileNameFromUrlPath(url)
        let ext = extensionOf(fileName)
        return isSupportedExtension(ext) ? ext : nil
    }

    static func fileNameFromUrlPath(_ url: String) -> String {
        var path = url.trimmingCharacters(in: .whitespaces)
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        let segment = path.components(separatedBy: "/").last ?? ""
        let decoded = decodeFileName(segment)
        return decoded.isEmpty ? "book.epub" : decoded
    }

    static func resolveFileName(url: String, contentDisposition: String?) -> String {
        if let name = fileNameFromContentDisposition(contentDisposition) { return name }
        return fileNameFromUrlPath(url)
    }

    static func fileNameFromContentDisposition(_ contentDisposition: String?) -> String? {
        guard let contentDisposition, !contentDisposition.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        if let star = firstMatch(#"filename\*=UTF-8''([^;\s]+)"#, in: contentDisposition) {
            return decodeFileName(star)
        }
        if let name = firstMatch(#"filename="?([^";\n]+)"?"#, in: contentDisposition) {
            return decodeFileName(name.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[captured])
    }

    private static func decodeFileName(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
