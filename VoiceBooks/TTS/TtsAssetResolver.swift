import Foundation

/// Resolves the on-disk model layout for VITS / Kokoro / Kitten models.
/// Mirrors the Kotlin `resolveTtsAssets` rules.
struct ResolvedTtsAssets {
    var modelName: String
    var voices: String
    var lexicon: String
    var dataDir: String
    var dictDir: String
    var ruleFsts: String
}

enum TtsAssetResolver {
    private static let fstFiles = ["phone.fst", "number.fst", "date.fst", "new_heteronym.fst"]
    private static let kokoroFstFiles = ["phone-zh.fst", "date-zh.fst", "number-zh.fst"]

    static func requiresBatchSynthesis(_ modelType: String) -> Bool {
        modelType == "kokoro" || modelType == "kitten"
    }

    static func resolve(modelDir: URL, modelType: String) -> ResolvedTtsAssets? {
        switch modelType {
        case "kokoro": return resolveKokoro(modelDir)
        case "kitten": return resolveKitten(modelDir)
        default: return resolveVits(modelDir)
        }
    }

    static func isModelLayoutValid(_ modelDir: URL, modelType: String = "vits") -> Bool {
        resolve(modelDir: modelDir, modelType: modelType) != nil
    }

    private static func children(of dir: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
        )
    }

    private static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func ext(_ url: URL) -> String { url.pathExtension.lowercased() }
    private static func name(_ url: URL) -> String { url.lastPathComponent }

    private static func resolveVits(_ modelDir: URL) -> ResolvedTtsAssets? {
        guard let children = children(of: modelDir) else { return nil }
        let preferInt8 = name(modelDir).lowercased().contains("int8")
        let onnxCandidates = children.filter {
            isFile($0) && ext($0) == "onnx" && !name($0).lowercased().contains("espeak")
        }
        let onnxFile: URL?
        if preferInt8 {
            onnxFile = onnxCandidates.first { name($0).lowercased().contains("int8") }
                ?? onnxCandidates.first { !name($0).lowercased().contains("int8") }
        } else {
            onnxFile = onnxCandidates.first { !name($0).lowercased().contains("int8") }
                ?? onnxCandidates.first
        }
        guard let onnxFile else { return nil }
        guard isFile(modelDir.appendingPathComponent("tokens.txt")) else { return nil }

        let espeakDir = children.first {
            isDirectory($0) && (name($0).lowercased().contains("espeak") || name($0) == "espeak-ng-data")
        }
        let dictDirFile = children.first { isDirectory($0) && name($0) == "dict" }
        let lexiconFile = children.first {
            isFile($0) && (name($0) == "lexicon.txt" || name($0).hasSuffix("lexicon.txt"))
        }
        let ruleFsts = fstFiles
            .map { modelDir.appendingPathComponent($0) }
            .filter { isFile($0) }
            .map { $0.path }
            .joined(separator: ",")

        let dataDir = espeakDir?.path ?? ""
        let dictDir = dictDirFile?.path ?? ""
        let lexicon = lexiconFile.map { name($0) } ?? ""

        if !lexicon.isEmpty && dataDir.isEmpty && dictDir.isEmpty && ruleFsts.isEmpty {
            return nil
        }
        return ResolvedTtsAssets(
            modelName: name(onnxFile), voices: "", lexicon: lexicon,
            dataDir: dataDir, dictDir: dictDir, ruleFsts: ruleFsts
        )
    }

    private static func resolveKokoro(_ modelDir: URL) -> ResolvedTtsAssets? {
        guard let children = children(of: modelDir) else { return nil }
        guard isFile(modelDir.appendingPathComponent("tokens.txt")) else { return nil }
        guard isFile(modelDir.appendingPathComponent("voices.bin")) else { return nil }

        let onnxFile = children.first {
            isFile($0) && ext($0) == "onnx" && !name($0).lowercased().contains("espeak")
                && (name($0) == "model.onnx" || name($0).hasPrefix("model"))
        } ?? children.first {
            isFile($0) && ext($0) == "onnx" && !name($0).lowercased().contains("espeak")
        }
        guard let onnxFile else { return nil }

        guard let espeakDir = children.first(where: {
            isDirectory($0) && (name($0).lowercased().contains("espeak") || name($0) == "espeak-ng-data")
        }) else { return nil }

        let lexiconFiles = children
            .filter { isFile($0) && name($0).hasPrefix("lexicon") && name($0).hasSuffix(".txt") }
            .sorted { name($0) < name($1) }
        let modelDirPath = modelDir.path
        let dictDirFile = children.first { isDirectory($0) && name($0) == "dict" }

        let lexicon = lexiconFiles.map { "\(modelDirPath)/\(name($0))" }.joined(separator: ",")

        if !lexiconFiles.isEmpty && dictDirFile == nil {
            Log.error("TtsAssetResolver", "Kokoro multi-lang requires dict/ directory in \(modelDirPath)")
            return nil
        }
        if lexiconFiles.isEmpty && dictDirFile != nil {
            Log.error("TtsAssetResolver", "Kokoro dict/ present but lexicon-*.txt missing in \(modelDirPath)")
            return nil
        }

        let ruleFsts = kokoroFstFiles
            .map { modelDir.appendingPathComponent($0) }
            .filter { isFile($0) }
            .map { "\(modelDirPath)/\(name($0))" }
            .joined(separator: ",")

        return ResolvedTtsAssets(
            modelName: name(onnxFile), voices: "voices.bin", lexicon: lexicon,
            dataDir: espeakDir.path, dictDir: dictDirFile?.path ?? "", ruleFsts: ruleFsts
        )
    }

    private static func resolveKitten(_ modelDir: URL) -> ResolvedTtsAssets? {
        guard let children = children(of: modelDir) else { return nil }
        guard isFile(modelDir.appendingPathComponent("tokens.txt")) else { return nil }
        guard isFile(modelDir.appendingPathComponent("voices.bin")) else { return nil }

        let onnxFile = children.first {
            isFile($0) && ext($0) == "onnx" && !name($0).lowercased().contains("espeak")
                && name($0).hasPrefix("model")
        }
        guard let onnxFile else { return nil }

        guard let espeakDir = children.first(where: {
            isDirectory($0) && (name($0).lowercased().contains("espeak") || name($0) == "espeak-ng-data")
        }) else { return nil }

        return ResolvedTtsAssets(
            modelName: name(onnxFile), voices: "voices.bin", lexicon: "",
            dataDir: espeakDir.path, dictDir: "", ruleFsts: ""
        )
    }
}
