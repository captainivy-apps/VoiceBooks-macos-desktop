import Foundation
import Combine

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var models: [TtsModelEntity] = []
    @Published private(set) var benchmarks: [TtsModelBenchmarkEntity] = []
    @Published var languageFilter: String? = nil
    @Published var keepScreenOn = true
    @Published var previewText = ""
    @Published var engineSwitchState: EngineSwitchState = .idle
    @Published var downloadProgress: [String: Float] = [:]
    @Published var previewingModelId: String?
    @Published var previewMessage: String?
    @Published var applying = false

    /// Pending (draft) default model + per-model speaker selections.
    @Published private var pendingModelId: String?
    @Published private var pendingSpeakerIds: [String: Int] = [:]
    private var draftInitialized = false

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var defaultModelId: String? { models.first(where: { $0.isDefault })?.id }
    var pendingDefaultModelId: String? { pendingModelId ?? defaultModelId }
    var isPreviewing: Bool { previewingModelId != nil }

    func refresh() async {
        models = (try? await services.ttsRepository.allModels()) ?? []
        benchmarks = (try? await services.ttsRepository.allBenchmarks()) ?? []
        keepScreenOn = AppSettings.keepScreenOn
        previewText = AppSettings.ttsPreviewText
        if !draftInitialized {
            pendingModelId = defaultModelId
            pendingSpeakerIds = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.speakerId) })
            draftInitialized = true
        }
    }

    func setKeepScreenOn(_ value: Bool) {
        keepScreenOn = value
        AppSettings.keepScreenOn = value
    }

    func setPreviewText(_ value: String) {
        previewText = value
        AppSettings.ttsPreviewText = value
    }

    func selectLanguageFilter(_ groupId: String?) {
        languageFilter = groupId
    }

    var filteredGroups: [(group: TtsLanguageGroup, models: [TtsModelEntity])] {
        let filtered: [TtsModelEntity]
        if let languageFilter {
            filtered = models.filter { TtsLanguageGroups.groupFor($0.language).id == languageFilter }
        } else {
            filtered = models
        }
        return TtsLanguageGroups.groupModels(filtered)
    }

    var distinctGroups: [TtsLanguageGroup] {
        TtsLanguageGroups.distinctGroups(models)
    }

    func speakerId(for modelId: String) -> Int {
        pendingSpeakerIds[modelId] ?? models.first(where: { $0.id == modelId })?.speakerId ?? 0
    }

    func maxSpeakerCount(for modelId: String) -> Int {
        BuiltInTtsModels.info(for: modelId)?.speakerCount ?? 1
    }

    /// Draft selection of the default engine (does not persist until applied).
    func selectModel(_ modelId: String) {
        pendingModelId = modelId
        if pendingSpeakerIds[modelId] == nil {
            pendingSpeakerIds[modelId] = models.first(where: { $0.id == modelId })?.speakerId ?? 0
        }
    }

    func updateSpeaker(modelId: String, speakerId: Int) {
        pendingSpeakerIds[modelId] = max(0, min(speakerId, maxSpeakerCount(for: modelId) - 1))
    }

    /// Whether the given model is the pending default AND there are unapplied changes.
    func showPendingApply(for modelId: String) -> Bool {
        pendingDefaultModelId == modelId && hasPendingChanges
    }

    var hasPendingChanges: Bool {
        guard draftInitialized else { return false }
        if pendingModelId != defaultModelId { return true }
        for (modelId, speaker) in pendingSpeakerIds {
            if let model = models.first(where: { $0.id == modelId }), model.speakerId != speaker {
                return true
            }
        }
        return false
    }

    func applyPending() async {
        guard let pendingModelId, hasPendingChanges else { return }
        engineSwitchState = .applying
        applying = true
        services.ttsSettingsGate.setBlocking(true)
        stopPreview()
        if PlaybackController.shared.snapshot.playbackState == .playing {
            services.playbackEngine.pause()
        }

        var speakerIds = pendingSpeakerIds
        speakerIds[pendingModelId] = pendingSpeakerIds[pendingModelId]
            ?? models.first(where: { $0.id == pendingModelId })?.speakerId ?? 0

        if let model = models.first(where: { $0.id == pendingModelId }) {
            var target = model
            target.speakerId = speakerIds[pendingModelId] ?? model.speakerId
            let initResult = await services.sherpaCoordinator.ensureInitialized(target)
            guard initResult.isSuccess else {
                engineSwitchState = .failed
                applying = false
                services.ttsSettingsGate.setBlocking(false)
                previewMessage = initResult.userMessage
                AppNotifier.shared.show(initResult.userMessage, long: true)
                return
            }
        }

        await services.ttsRepository.applyTtsConfiguration(defaultModelId: pendingModelId, speakerIds: speakerIds)
        services.playbackEngine.syncTtsEngineAsync()
        services.ttsSettingsGate.setBlocking(false)
        engineSwitchState = .idle
        applying = false
        AppNotifier.shared.show("引擎已切换完成")
        draftInitialized = false
        await refresh()
    }

    func discardChanges() {
        pendingModelId = defaultModelId
        pendingSpeakerIds = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.speakerId) })
        engineSwitchState = .idle
        previewMessage = nil
    }

    func downloadModel(_ modelId: String, useMirror: Bool) async {
        downloadProgress[modelId] = 0
        let result = await services.ttsRepository.downloadModel(modelId, useMirror: useMirror) { [weak self] progress in
            Task { @MainActor in self?.downloadProgress[modelId] = progress }
        }
        downloadProgress.removeValue(forKey: modelId)
        if case .failure(let message) = result {
            AppNotifier.shared.show(message, long: true)
        }
        await refresh()
    }

    func deleteModel(_ modelId: String) async {
        await services.ttsRepository.deleteModel(modelId)
        if defaultModelId == modelId {
            pendingModelId = nil
            draftInitialized = false
        }
        await refresh()
    }

    func preview(_ modelId: String) async {
        // Toggle: tapping the same model again stops preview.
        if previewingModelId == modelId {
            stopPreview()
            return
        }
        guard let model = models.first(where: { $0.id == modelId }) else { return }
        if model.downloadState != TtsDownloadState.downloaded.rawValue {
            AppNotifier.shared.show("模型未下载")
            return
        }
        stopPreview()
        previewingModelId = modelId
        previewMessage = "正在合成试听语音…"
        let sample = previewText.trimmed.isEmpty ? defaultPreviewSample(for: model.language) : previewText
        let speaker = speakerId(for: modelId)
        let outcome = await services.ttsPreviewController.preview(model: model, sampleText: sample, speakerId: speaker)
        previewingModelId = nil
        switch outcome {
        case .success(let benchmark):
            await services.ttsRepository.saveBenchmark(benchmark)
            previewMessage = benchmarkSummary(benchmark)
            await refresh()
        case .failure(let message):
            previewMessage = message
            AppNotifier.shared.show(message, long: true)
        case .cancelled:
            previewMessage = nil
        }
    }

    func stopPreview() {
        services.ttsPreviewController.stopPlayback()
        previewingModelId = nil
    }

    func benchmark(for modelId: String, speakerId: Int) -> TtsModelBenchmarkEntity? {
        benchmarks.first { $0.modelId == modelId && $0.speakerId == speakerId }
    }

    private func benchmarkSummary(_ benchmark: TtsModelBenchmark) -> String {
        String(
            format: "合成 %dms · 音频 %.1fs · RTF %.2f · %dkHz",
            benchmark.synthesisMs,
            Double(benchmark.audioDurationMs) / 1000.0,
            benchmark.rtf,
            benchmark.sampleRate / 1000
        )
    }

    private func defaultPreviewSample(for language: String) -> String {
        if language.contains("zh") || language.contains("yue") {
            return "我与父亲不相见已二年余了，我最不能忘记的是他的背影。那年冬天，祖母死了，父亲的差使也交卸了，正是祸不单行的日子。"
        }
        return "Four score and seven years ago our fathers brought forth on this continent, a new nation, conceived in Liberty, and dedicated to the proposition that all men are created equal."
    }
}
