import Foundation

/// Manages the built-in TTS model catalog, download state and benchmarks.
actor TtsRepository {
    private let ttsStore: TtsStore
    private let fileStorage: FileStorage
    private let downloader = TtsModelDownloader()

    init(ttsStore: TtsStore, fileStorage: FileStorage) {
        self.ttsStore = ttsStore
        self.fileStorage = fileStorage
    }

    func allModels() async throws -> [TtsModelEntity] {
        try await ttsStore.models()
    }

    func getModel(_ modelId: String) async throws -> TtsModelEntity? {
        try await ttsStore.getModel(modelId)
    }

    func getDefaultModel() async throws -> TtsModelEntity? {
        try await ttsStore.getDefaultModel()
    }

    func allBenchmarks() async throws -> [TtsModelBenchmarkEntity] {
        try await ttsStore.benchmarks()
    }

    func ensureBuiltInModels() async {
        await recoverInterruptedDownloads()

        let existing = (try? await ttsStore.models()) ?? []
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for info in BuiltInTtsModels.models {
            if let current = existingById[info.id] {
                var updated = current
                updated.name = info.name
                updated.language = info.language
                updated.sizeBytes = info.sizeBytes
                updated.downloadUrl = info.downloadUrl
                updated.modelType = info.modelType
                try? await ttsStore.upsert(updated)
            } else {
                let entity = TtsModelEntity(
                    id: info.id, name: info.name, language: info.language, sizeBytes: info.sizeBytes,
                    downloadUrl: info.downloadUrl, localPath: nil,
                    downloadState: TtsDownloadState.notDownloaded.rawValue, downloadError: nil,
                    isDefault: false, modelType: info.modelType, speakerId: info.speakerId
                )
                try? await ttsStore.upsert(entity)
            }
        }

        if existing.isEmpty, let first = BuiltInTtsModels.models.first {
            try? await ttsStore.clearDefault()
            try? await ttsStore.setDefault(first.id)
            AppSettings.defaultTtsEngine = first.id
        }
    }

    func updateSpeakerId(_ modelId: String, speakerId: Int) async {
        guard let model = try? await ttsStore.getModel(modelId) else { return }
        let maxSpeaker = BuiltInTtsModels.info(for: modelId)?.speakerCount ?? 1
        var updated = model
        updated.speakerId = min(max(speakerId, 0), maxSpeaker - 1)
        try? await ttsStore.upsert(updated)
    }

    func applyTtsConfiguration(defaultModelId: String, speakerIds: [String: Int]) async {
        let models = (try? await ttsStore.models()) ?? []
        for model in models {
            let pending = speakerIds[model.id] ?? model.speakerId
            let maxSpeaker = BuiltInTtsModels.info(for: model.id)?.speakerCount ?? 1
            let clamped = min(max(pending, 0), maxSpeaker - 1)
            if model.speakerId != clamped {
                var updated = model
                updated.speakerId = clamped
                try? await ttsStore.upsert(updated)
            }
        }
        try? await ttsStore.clearDefault()
        try? await ttsStore.setDefault(defaultModelId)
        AppSettings.defaultTtsEngine = defaultModelId
    }

    func saveBenchmark(_ benchmark: TtsModelBenchmark) async {
        try? await ttsStore.upsertBenchmark(TtsModelBenchmarkEntity(
            modelId: benchmark.modelId, speakerId: benchmark.speakerId,
            synthesisMs: benchmark.synthesisMs, audioDurationMs: benchmark.audioDurationMs,
            rtf: benchmark.rtf, sampleRate: benchmark.sampleRate, benchmarkedAt: benchmark.benchmarkedAt
        ))
    }

    func getBenchmark(_ modelId: String, speakerId: Int) async -> TtsModelBenchmark? {
        guard let entity = try? await ttsStore.getBenchmark(modelId, speakerId: speakerId) else { return nil }
        return TtsModelBenchmark(
            modelId: entity.modelId, speakerId: entity.speakerId, synthesisMs: entity.synthesisMs,
            audioDurationMs: entity.audioDurationMs, rtf: entity.rtf, sampleRate: entity.sampleRate,
            benchmarkedAt: entity.benchmarkedAt
        )
    }

    func downloadModel(
        _ modelId: String,
        useMirror: Bool = false,
        onProgress: @escaping (Float) -> Void
    ) async -> TtsModelDownloadResult {
        guard let model = try? await ttsStore.getModel(modelId) else {
            return .failure("找不到模型")
        }
        try? await ttsStore.updateDownloadState(modelId, state: .downloading, localPath: nil, error: nil)

        let targetDir = fileStorage.ttsModelDir(modelId: modelId)
        try? FileManager.default.removeItem(at: targetDir)
        Paths.createIfNeeded(targetDir)

        let url: String
        if useMirror {
            guard let mirror = BuiltInTtsModels.info(for: modelId)?.mirrorDownloadUrl else {
                try? await ttsStore.updateDownloadState(modelId, state: .failed, localPath: nil, error: "该模型暂无镜像")
                return .failure("该模型暂无镜像")
            }
            url = mirror
        } else {
            url = model.downloadUrl
        }

        let result = await downloader.downloadAndExtract(url: url, targetDir: targetDir, onProgress: onProgress)
        if case .failure(let message) = result {
            cleanupPartialDownload(modelId)
            try? await ttsStore.updateDownloadState(modelId, state: .failed, localPath: nil, error: message)
            return result
        }
        if TtsAssetResolver.isModelLayoutValid(targetDir, modelType: model.modelType) {
            try? await ttsStore.updateDownloadState(modelId, state: .downloaded, localPath: targetDir.path, error: nil)
            return .success
        }
        cleanupPartialDownload(modelId)
        let error = "模型文件不完整或格式无效"
        try? await ttsStore.updateDownloadState(modelId, state: .failed, localPath: nil, error: error)
        return .failure(error)
    }

    func recoverInterruptedDownloads() async {
        let models = (try? await ttsStore.models()) ?? []
        for model in models where model.downloadState == TtsDownloadState.downloading.rawValue {
            cleanupPartialDownload(model.id)
            await markDownloadInterrupted(model.id)
        }
    }

    func setDefaultModel(_ modelId: String) async {
        try? await ttsStore.clearDefault()
        try? await ttsStore.setDefault(modelId)
        AppSettings.defaultTtsEngine = modelId
    }

    func deleteModel(_ modelId: String) async {
        guard let model = try? await ttsStore.getModel(modelId) else { return }
        if let path = model.localPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        fileStorage.deleteTtsModel(modelId: modelId)
        try? await ttsStore.updateDownloadState(modelId, state: .notDownloaded, localPath: nil, error: nil)
    }

    private func markDownloadInterrupted(_ modelId: String) async {
        try? await ttsStore.updateDownloadState(modelId, state: .failed, localPath: nil, error: "下载已中断，请重试")
    }

    private func cleanupPartialDownload(_ modelId: String) {
        try? FileManager.default.removeItem(at: fileStorage.ttsModelDir(modelId: modelId))
        try? FileManager.default.removeItem(at: fileStorage.ttsArchiveFile(modelId: modelId))
    }
}
