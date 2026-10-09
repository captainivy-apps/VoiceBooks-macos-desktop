import Foundation

/// Adapts book text to the active TTS model language.
enum TtsTextAdapter {
    static func adaptForModel(_ text: String, modelLanguage: String) -> String? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return nil }

        let lang = modelLanguage.lowercased()
        let supportsEn = lang.contains("en")
        let supportsZh = lang.contains("zh") || lang.contains("yue")

        if supportsEn && supportsZh { return trimmed }
        if supportsZh && !supportsEn {
            let stripped = stripLatinWords(trimmed)
            return hasCjkOrDigit(stripped) ? stripped : nil
        }
        if supportsEn && !supportsZh {
            let stripped = stripCjk(trimmed)
            return hasLatinLetter(stripped) ? stripped : nil
        }
        return trimmed
    }

    private static func stripLatinWords(_ text: String) -> String {
        var result = ""
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if isLatinLetter(char) {
                while index < chars.count {
                    let current = chars[index]
                    if isLatinLetter(current) || current == "'" || current == "-" || current == "." {
                        index += 1
                    } else {
                        break
                    }
                }
                continue
            }
            result.append(char)
            index += 1
        }
        return collapseWhitespace(result)
    }

    private static func stripCjk(_ text: String) -> String {
        var result = ""
        for char in text where !isCjk(char) {
            result.append(char)
        }
        return collapseWhitespace(result)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
    }

    private static func hasCjkOrDigit(_ text: String) -> Bool {
        text.contains { isCjk($0) || $0.isNumber }
    }

    private static func hasLatinLetter(_ text: String) -> Bool {
        text.contains { isLatinLetter($0) }
    }

    private static func isLatinLetter(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else { return false }
        return (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    private static func isCjk(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value)
                || (0xF900...0xFAFF).contains(value)
        }
    }
}
