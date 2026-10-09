import Foundation

extension String {
    func substringAfterLast(_ separator: Character, default defaultValue: String = "") -> String {
        guard let index = lastIndex(of: separator) else { return defaultValue }
        return String(self[self.index(after: index)...])
    }

    func substringBeforeLast(_ separator: Character) -> String {
        guard let index = lastIndex(of: separator) else { return self }
        return String(self[..<index])
    }
}
