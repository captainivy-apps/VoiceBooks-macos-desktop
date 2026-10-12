import XCTest
@testable import VoiceBooks

final class BuiltInTtsModelsTests: XCTestCase {
    func testNoInt8ModelsRemain() {
        let int8 = BuiltInTtsModels.models.filter { $0.id.lowercased().contains("int8") }
        XCTAssertTrue(int8.isEmpty, "int8 models should have been removed: \(int8.map(\.id))")
    }

    func testStandardMeloEntryUsesArchive() {
        guard let info = BuiltInTtsModels.info(for: "vits-melo-tts-zh_en") else {
            return XCTFail("missing entry")
        }
        XCTAssertEqual(info.language, "zh+en")
        XCTAssertEqual(info.modelType, "vits")
        XCTAssertNil(info.fileBaseUrl)
        XCTAssertTrue(info.files.isEmpty)
        XCTAssertTrue(info.downloadUrl.hasSuffix("vits-melo-tts-zh_en.tar.bz2"))
    }

    func testMatchaBilingualEntry() {
        guard let info = BuiltInTtsModels.info(for: "matcha-icefall-zh-en") else {
            return XCTFail("missing matcha entry")
        }
        XCTAssertEqual(info.language, "zh+en")
        XCTAssertEqual(info.modelType, "matcha")
        XCTAssertEqual(info.family, .matcha)
        XCTAssertEqual(info.speakerCount, 1)
        XCTAssertTrue(info.downloadUrl.hasSuffix("matcha-icefall-zh-en.tar.bz2"))
        XCTAssertEqual(info.auxiliaryFiles.count, 1)
        XCTAssertEqual(info.auxiliaryFiles.first?.relativePath, "vocos-16khz-univ.onnx")
        XCTAssertTrue(info.auxiliaryFiles.first?.url.contains("vocoder-models/vocos-16khz-univ.onnx") == true)
    }

    func testMatchaIsNotBatchOnly() {
        XCTAssertFalse(TtsAssetResolver.requiresBatchSynthesis("matcha"))
    }

    func testMatchaAssetsResolve() throws {
        let dir = try makeMatchaDir(includeVocoder: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let assets = TtsAssetResolver.resolve(modelDir: dir, modelType: "matcha")
        XCTAssertEqual(assets?.modelName, "model-steps-3.onnx")
        XCTAssertEqual(canonical(assets?.vocoder), canonical(dir.appendingPathComponent("vocos-16khz-univ.onnx").path))
        XCTAssertEqual(assets?.lexicon, "lexicon.txt")
        XCTAssertEqual(canonical(assets?.dataDir), canonical(dir.appendingPathComponent("espeak-ng-data").path))
        XCTAssertTrue(assets?.ruleFsts.contains("phone-zh.fst") == true)
    }

    func testMatchaWithoutVocoderIsInvalid() throws {
        let dir = try makeMatchaDir(includeVocoder: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(TtsAssetResolver.resolve(modelDir: dir, modelType: "matcha"))
        XCTAssertFalse(TtsAssetResolver.isModelLayoutValid(dir, modelType: "matcha"))
    }

    func testAuxiliarySourceURLUsesMirrorWhenConfigured() {
        let aux = TtsAuxiliaryFile(
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-16khz-univ.onnx",
            relativePath: "vocos-16khz-univ.onnx")

        XCTAssertEqual(TtsRepository.auxiliarySourceURL(aux, mirrorBaseUrl: nil), aux.url)
        XCTAssertEqual(TtsRepository.auxiliarySourceURL(aux, mirrorBaseUrl: "   "), aux.url)
        XCTAssertEqual(
            TtsRepository.auxiliarySourceURL(aux, mirrorBaseUrl: "https://www.galaxyrover.com/mirrors"),
            "https://www.galaxyrover.com/mirrors/vocos-16khz-univ.onnx")
        XCTAssertEqual(
            TtsRepository.auxiliarySourceURL(aux, mirrorBaseUrl: "https://www.galaxyrover.com/mirrors/"),
            "https://www.galaxyrover.com/mirrors/vocos-16khz-univ.onnx")
    }

    private func makeMatchaDir(includeVocoder: Bool) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("matcha-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var files = ["model-steps-3.onnx", "tokens.txt", "lexicon.txt",
                     "phone-zh.fst", "date-zh.fst", "number-zh.fst"]
        if includeVocoder { files.append("vocos-16khz-univ.onnx") }
        for file in files {
            fm.createFile(atPath: dir.appendingPathComponent(file).path, contents: Data("x".utf8))
        }
        try fm.createDirectory(at: dir.appendingPathComponent("espeak-ng-data"),
                               withIntermediateDirectories: true)
        return dir
    }

    private func canonical(_ path: String?) -> String? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
