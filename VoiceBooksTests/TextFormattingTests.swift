import XCTest
@testable import VoiceBooks

final class ProgressFormatTests: XCTestCase {
    func testRatio() {
        XCTAssertEqual(ProgressFormat.percentSuffix(Float(0.5)), "(50.00%)")
    }

    func testCurrentTotalZero() {
        XCTAssertEqual(ProgressFormat.percentSuffix(0, 500), "(0.00%)")
    }

    func testCurrentTotalMid() {
        XCTAssertEqual(ProgressFormat.percentSuffix(42, 500), "(8.40%)")
    }

    func testCurrentTotalNearEnd() {
        XCTAssertEqual(ProgressFormat.percentSuffix(499, 500), "(99.80%)")
    }

    func testClampsAboveOne() {
        XCTAssertEqual(ProgressFormat.percentSuffix(Float(1.5)), "(100.00%)")
    }

    func testClampsBelowZero() {
        XCTAssertEqual(ProgressFormat.percentSuffix(Float(-0.1)), "(0.00%)")
    }
}

final class TtsTextAdapterTests: XCTestCase {
    func testChineseModelSkipsPureEnglish() {
        XCTAssertNil(TtsTextAdapter.adaptForModel("Cover", modelLanguage: "zh"))
        XCTAssertNil(TtsTextAdapter.adaptForModel("  Hello World  ", modelLanguage: "zh"))
    }

    func testChineseModelKeepsChineseAndStripsLatin() {
        XCTAssertEqual(TtsTextAdapter.adaptForModel("第一章 Cover", modelLanguage: "zh"), "第一章")
        XCTAssertEqual(TtsTextAdapter.adaptForModel("这是 Cover 测试。", modelLanguage: "zh"), "这是 测试。")
        XCTAssertEqual(TtsTextAdapter.adaptForModel("第Cover章", modelLanguage: "zh"), "第章")
    }

    func testBilingualModelKeepsEnglish() {
        XCTAssertEqual(TtsTextAdapter.adaptForModel("Cover", modelLanguage: "zh+en"), "Cover")
    }

    func testEnglishModelSkipsPureChinese() {
        XCTAssertNil(TtsTextAdapter.adaptForModel("你好世界", modelLanguage: "en"))
    }

    func testEnglishModelKeepsLatin() {
        XCTAssertEqual(TtsTextAdapter.adaptForModel("Hello world", modelLanguage: "en"), "Hello world")
    }
}

final class TtsTextChunkerTests: XCTestCase {
    func testShortTextSingleChunk() {
        XCTAssertEqual(TtsTextChunker.chunk("你好世界。", maxChars: 400), ["你好世界。"])
    }

    func testSplitsLongTextBySentenceDelimiters() {
        let part1 = String(repeating: "这是一段比较长的测试文本。", count: 35)
        let part2 = "第二句开始。"
        let chunks = TtsTextChunker.chunk(part1 + part2, maxChars: 400)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 400 })
        XCTAssertEqual(chunks.joined(), part1 + part2)
    }

    func testSplitsVeryLongSegmentWithoutDelimiters() {
        let text = String(repeating: "字", count: 900)
        let chunks = TtsTextChunker.chunk(text, maxChars: 400)
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 400 })
        XCTAssertEqual(chunks.joined(), text)
    }
}

final class MD5HasherTests: XCTestCase {
    func testDataMatchesKnownHash() {
        XCTAssertEqual(MD5Hasher.md5(of: Data("hello".utf8)), "5d41402abc4b2a76b9719d911017c592")
    }

    func testFileMatchesDataHash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("md5-\(UUID().uuidString).txt")
        try "hello world".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(MD5Hasher.md5(ofFile: url), MD5Hasher.md5(of: Data("hello world".utf8)))
    }
}

final class EbookUrlHelperTests: XCTestCase {
    func testValidHttpUrl() {
        XCTAssertTrue(EbookUrlHelper.isValidHttpUrl("http://example.com/book.epub"))
        XCTAssertTrue(EbookUrlHelper.isValidHttpUrl("https://example.com/book.epub"))
        XCTAssertTrue(EbookUrlHelper.isValidHttpUrl("  https://example.com/book.epub  "))
    }

    func testRejectsOtherSchemes() {
        XCTAssertFalse(EbookUrlHelper.isValidHttpUrl("ftp://example.com/book.epub"))
        XCTAssertFalse(EbookUrlHelper.isValidHttpUrl("not-a-url"))
        XCTAssertFalse(EbookUrlHelper.isValidHttpUrl(""))
    }

    func testExtensionFromUrl() {
        XCTAssertEqual(EbookUrlHelper.extensionFromUrl("https://example.com/books/demo.epub"), "epub")
        XCTAssertNil(EbookUrlHelper.extensionFromUrl("https://example.com/book.txt?token=abc"))
        XCTAssertNil(EbookUrlHelper.extensionFromUrl("https://example.com/download"))
        XCTAssertNil(EbookUrlHelper.extensionFromUrl("https://example.com/book.pdf"))
    }

    func testFileNameFromUrlPath() {
        XCTAssertEqual(EbookUrlHelper.fileNameFromUrlPath("https://example.com/files/my%20book.epub?sig=1"), "my book.epub")
        XCTAssertEqual(EbookUrlHelper.fileNameFromUrlPath("https://example.com/"), "book.epub")
    }

    func testResolveFileNamePrefersContentDisposition() {
        XCTAssertEqual(
            EbookUrlHelper.resolveFileName(url: "https://example.com/file?id=1", contentDisposition: "attachment; filename=\"downloaded.epub\""),
            "downloaded.epub"
        )
        XCTAssertEqual(
            EbookUrlHelper.resolveFileName(url: "https://example.com/file", contentDisposition: "attachment; filename*=UTF-8''utf8%20name.epub"),
            "utf8 name.epub"
        )
    }

    func testSupportedExtension() {
        XCTAssertTrue(EbookUrlHelper.isSupportedExtension("epub"))
        XCTAssertFalse(EbookUrlHelper.isSupportedExtension("AZW3"))
        XCTAssertFalse(EbookUrlHelper.isSupportedExtension("txt"))
        XCTAssertFalse(EbookUrlHelper.isSupportedExtension("pdf"))
    }
}
