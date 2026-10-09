import Foundation

/// Port of the Kotlin `SentenceSplitter` (itself a port of
/// `audio_books/comm/scan_text.go ScanTextFileBySentence`).
///
/// Sentence boundaries are expressed as UTF-8 **byte** offsets into the text
/// file, matching the on-disk sentence index. Iteration mirrors Kotlin `Char`
/// semantics by walking UTF-16 code units.
enum SentenceSplitter {
    static let previewMaxChars = 120

    private static let delimiters: Set<UInt16> = [
        0x3002, // 。
        0xFF01, // ！
        0xFF1F, // ？
        0x002E, // .
        0x0021, // !
        0x003F, // ?
        0xFF1B, // ；
        0x003B, // ;
        0x000A, // \n
    ]

    static func split(_ text: String) -> [SentenceChunk] {
        guard !text.isEmpty else { return [] }
        let units = Array(text.utf16)
        let bytes = Array(text.utf8)
        let prefix = utf8Prefix(units)
        let offsets = scan(units, prefix: prefix, totalBytes: bytes.count)

        var chunks: [SentenceChunk] = []
        for idx in 0..<max(0, offsets.count - 1) {
            let start = offsets[idx]
            let end = offsets[idx + 1]
            if start >= end { continue }
            let sentenceText = String(decoding: bytes[start..<end], as: UTF8.self).trimmed
            if !sentenceText.isEmpty {
                chunks.append(SentenceChunk(
                    index: chunks.count,
                    byteOffsetStart: start,
                    byteOffsetEnd: end,
                    text: sentenceText
                ))
            }
        }
        return chunks
    }

    static func splitForImport(text: String) -> [SentenceIndexSlice] {
        guard !text.isEmpty else { return [] }
        let bytes = Array(text.utf8)
        return buildSlices(bytes: bytes, units: Array(text.utf16))
    }

    static func splitForImport(file: URL) -> [SentenceIndexSlice] {
        guard let bytes = try? Data(contentsOf: file), !bytes.isEmpty else { return [] }
        let byteArray = Array(bytes)
        let text = String(decoding: byteArray, as: UTF8.self)
        return buildSlices(bytes: byteArray, units: Array(text.utf16))
    }

    private static func buildSlices(bytes: [UInt8], units: [UInt16]) -> [SentenceIndexSlice] {
        let prefix = utf8Prefix(units)
        let offsets = scan(units, prefix: prefix, totalBytes: bytes.count)
        var slices: [SentenceIndexSlice] = []
        for idx in 0..<max(0, offsets.count - 1) {
            let start = offsets[idx]
            let end = offsets[idx + 1]
            if start >= end { continue }
            let trimmed = String(decoding: bytes[start..<end], as: UTF8.self).trimmed
            if !trimmed.isEmpty {
                slices.append(SentenceIndexSlice(
                    index: slices.count,
                    byteOffsetStart: start,
                    byteOffsetEnd: end,
                    textPreview: String(trimmed.prefix(previewMaxChars))
                ))
            }
        }
        return slices
    }

    /// Prefix sums of UTF-8 byte lengths for each UTF-16 code-unit boundary.
    private static func utf8Prefix(_ units: [UInt16]) -> [Int] {
        var prefix = [Int](repeating: 0, count: units.count + 1)
        var i = 0
        while i < units.count {
            let u = units[i]
            if u >= 0xD800 && u <= 0xDBFF, i + 1 < units.count,
               units[i + 1] >= 0xDC00, units[i + 1] <= 0xDFFF {
                prefix[i + 1] = prefix[i] + 2
                prefix[i + 2] = prefix[i] + 4
                i += 2
                continue
            }
            let len: Int
            if u < 0x80 {
                len = 1
            } else if u < 0x800 {
                len = 2
            } else {
                len = 3
            }
            prefix[i + 1] = prefix[i] + len
            i += 1
        }
        return prefix
    }

    private static func scan(_ runes: [UInt16], prefix: [Int], totalBytes: Int) -> [Int] {
        var offsets: [Int] = []
        var i = 0
        var byteOffset = 0

        while i < runes.count {
            offsets.append(byteOffset)
            var j = i
            while j < runes.count {
                if delimiters.contains(runes[j]) {
                    if runes[j] == 0x002E, j > 0, j + 1 < runes.count,
                       isDigit(runes[j - 1]), isDigit(runes[j + 1]) {
                        j += 1
                        continue
                    }
                    j += 1
                    break
                }
                j += 1
            }
            let sentLen = j - i
            if sentLen == 0 { break }
            byteOffset += prefix[j] - prefix[i]
            i = j
        }

        if offsets.isEmpty || offsets.last != totalBytes {
            offsets.append(totalBytes)
        }
        return offsets
    }

    private static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
