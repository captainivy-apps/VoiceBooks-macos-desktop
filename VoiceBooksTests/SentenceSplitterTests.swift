import XCTest
@testable import VoiceBooks

final class SentenceSplitterTests: XCTestCase {
    func testSplitsChineseSentences() {
        let chunks = SentenceSplitter.split("你好世界。这是第二句！还有第三句？")
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks[0].text.contains("你好世界"))
    }

    func testDoesNotSplitDecimalNumbers() {
        let chunks = SentenceSplitter.split("价格是3.14元。结束。")
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].text.contains("3.14"))
    }

    func testEmptyTextReturnsEmpty() {
        XCTAssertTrue(SentenceSplitter.split("").isEmpty)
        XCTAssertTrue(SentenceSplitter.splitForImport(text: "").isEmpty)
    }

    func testSplitForImportMatchesSplit() {
        let text = "Hello world. 你好世界。Second sentence!"
        let chunks = SentenceSplitter.split(text)
        let slices = SentenceSplitter.splitForImport(text: text)
        XCTAssertEqual(chunks.count, slices.count)
        for (chunk, slice) in zip(chunks, slices) {
            XCTAssertEqual(chunk.index, slice.index)
            XCTAssertEqual(chunk.byteOffsetStart, slice.byteOffsetStart)
            XCTAssertEqual(chunk.byteOffsetEnd, slice.byteOffsetEnd)
            XCTAssertEqual(String(chunk.text.prefix(120)), slice.textPreview)
        }
    }

    func testSplitForImportFromFileMatchesString() throws {
        let text = "Line one.\nLine two. 第三行。"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sentence-split-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromFile = SentenceSplitter.splitForImport(file: url)
        let fromString = SentenceSplitter.splitForImport(text: text)
        XCTAssertEqual(fromString.count, fromFile.count)
        for (a, b) in zip(fromString, fromFile) {
            XCTAssertEqual(a.byteOffsetStart, b.byteOffsetStart)
            XCTAssertEqual(a.byteOffsetEnd, b.byteOffsetEnd)
            XCTAssertEqual(a.textPreview, b.textPreview)
        }
    }

    func testHandlesEmojiAndMixedScripts() {
        let text = "Hello 👋 world. 中文句子。Done!"
        let chunks = SentenceSplitter.split(text)
        let slices = SentenceSplitter.splitForImport(text: text)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.count, slices.count)
        for (chunk, slice) in zip(chunks, slices) {
            XCTAssertEqual(chunk.byteOffsetStart, slice.byteOffsetStart)
            XCTAssertEqual(chunk.byteOffsetEnd, slice.byteOffsetEnd)
        }
    }

    func testPreviewCappedAt120Chars() {
        let slices = SentenceSplitter.splitForImport(text: String(repeating: "测", count: 200) + "。")
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices[0].textPreview.count, 120)
    }

    func testLargeTextCompletesQuickly() {
        let paragraph = "这是一段测试文本，用于模拟长篇小说导入时的分句压力。The quick brown fox jumps over the lazy dog. "
        let text = String(repeating: paragraph, count: 3200)
        let start = Date()
        let slices = SentenceSplitter.splitForImport(text: text)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(slices.count, 100)
        XCTAssertLessThan(elapsed, 15.0)
    }
}
