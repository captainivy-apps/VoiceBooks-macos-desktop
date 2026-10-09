import Foundation

/// Splits long paragraphs into TTS-safe chunks.
enum TtsTextChunker {
    private static let secondaryDelims: Set<Character> = ["，", "、", ",", "；", ";", "：", ":", " "]

    static func chunk(_ text: String, maxChars: Int) -> [String] {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return [] }
        if maxChars <= 0 || trimmed.count <= maxChars { return [trimmed] }

        let sentences = SentenceSplitter.split(trimmed)
            .map { $0.text.trimmed }
            .filter { !$0.isEmpty }
        if sentences.count > 1 {
            return sentences.flatMap { chunk($0, maxChars: maxChars) }
        }
        return splitLongSegment(trimmed, maxChars: maxChars)
    }

    private static func splitLongSegment(_ text: String, maxChars: Int) -> [String] {
        if text.count <= maxChars { return [text] }
        let chars = Array(text)
        var result: [String] = []
        var start = 0
        while start < chars.count {
            let remaining = chars.count - start
            if remaining <= maxChars {
                let piece = String(chars[start...]).trimmed
                if !piece.isEmpty { result.append(piece) }
                break
            }
            let windowEnd = start + maxChars
            var splitAt = -1
            var j = windowEnd
            while j >= start + 1 {
                if secondaryDelims.contains(chars[j]) {
                    splitAt = j + 1
                    break
                }
                j -= 1
            }
            if splitAt <= start { splitAt = windowEnd }
            let piece = String(chars[start..<splitAt]).trimmed
            if !piece.isEmpty { result.append(piece) }
            start = splitAt
        }
        return result
    }
}
