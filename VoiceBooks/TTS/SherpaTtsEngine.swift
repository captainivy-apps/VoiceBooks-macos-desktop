import Foundation
import SherpaOnnx

enum SherpaModelLoadFailure {
    case missingDir
    case invalidLayout
    case invalidSampleRate
    case outOfMemory
    case nativeError
}

struct SherpaModelLoadResult {
    var failure: SherpaModelLoadFailure?
    var detail: String?

    var isSuccess: Bool { failure == nil }
    static let success = SherpaModelLoadResult(failure: nil, detail: nil)
    static func failed(_ failure: SherpaModelLoadFailure, _ detail: String? = nil) -> SherpaModelLoadResult {
        SherpaModelLoadResult(failure: failure, detail: detail)
    }
}

/// Native sherpa-onnx offline TTS engine (VITS / Kokoro / Kitten).
final class SherpaTtsEngine {
    let engineId = "sherpa_onnx"
    let engineName = "Sherpa-ONNX"

    /// Recursive: the streaming synthesis callback may re-enter engine
    /// accessors (e.g. `sampleRate()`) on the same thread, matching the Kotlin
    /// `ReentrantLock`.
    private let lock = NSRecursiveLock()
    private var tts: SherpaOnnxOfflineTtsWrapper?
    private var currentModelPath: String?
    private var currentModelType: String?
    private var modelSampleRate = 0
    private var isShutdown = false

    func isReady() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tts != nil
    }

    func isLoadedFor(modelPath: String, modelType: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tts != nil && currentModelPath == modelPath && currentModelType == modelType
    }

    func loadModel(modelPath: String, modelType: String) -> SherpaModelLoadResult {
        lock.lock(); defer { lock.unlock() }
        if isShutdown { return .failed(.nativeError, "engine shut down") }
        if currentModelPath == modelPath, currentModelType == modelType, tts != nil {
            return .success
        }
        releaseLocked()

        let modelDir = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(atPath: modelPath) else {
            Log.error("SherpaTtsEngine", "Model directory missing: \(modelPath)")
            return .failed(.missingDir)
        }
        guard let assets = TtsAssetResolver.resolve(modelDir: modelDir, modelType: modelType) else {
            Log.error("SherpaTtsEngine", "Invalid model layout: \(modelPath) type=\(modelType)")
            return .failed(.invalidLayout)
        }

        let numThreads: Int
        if modelType == "kokoro" || modelType == "kitten" {
            numThreads = 1
        } else {
            numThreads = min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 4)
        }

        let wrapper = Self.createWrapper(modelDir: modelDir, modelType: modelType, assets: assets, numThreads: numThreads)
        guard wrapper.tts != nil else {
            Log.error("SherpaTtsEngine", "Failed to create offline TTS: \(modelPath) type=\(modelType)")
            return .failed(.nativeError, "create returned nil")
        }
        let rate = Int(wrapper.sampleRate)
        guard rate > 0 else {
            Log.error("SherpaTtsEngine", "Invalid sample rate after load: \(modelPath)")
            return .failed(.invalidSampleRate)
        }
        tts = wrapper
        modelSampleRate = rate
        currentModelPath = modelPath
        currentModelType = modelType
        Log.info("SherpaTtsEngine", "Loaded TTS type=\(modelType) numThreads=\(numThreads) rate=\(rate) model=\(modelPath)")
        return .success
    }

    func getVoices() -> [TtsVoice] {
        lock.lock(); defer { lock.unlock() }
        let count = max(Int(tts?.numSpeakers ?? 1), 1)
        let voices = (0..<count).map { TtsVoice(id: String($0), name: "Speaker \($0)", language: "auto") }
        return voices.isEmpty ? [TtsVoice(id: "0", name: "默认音色", language: "auto")] : voices
    }

    func sampleRate() -> Int {
        lock.lock(); defer { lock.unlock() }
        return modelSampleRate
    }

    func resolveSpeakerId(_ speakerId: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let engine = tts else { return max(speakerId, 0) }
        let count = max(Int(engine.numSpeakers), 1)
        let resolved = min(max(speakerId, 0), count - 1)
        if resolved != speakerId {
            Log.warn("SherpaTtsEngine", "Clamped speakerId \(speakerId) -> \(resolved) (numSpeakers=\(count))")
        }
        return resolved
    }

    func synthesize(text: String, speed: Float = 1.0, speakerId: Int = 0) -> SynthesizedAudio? {
        lock.lock(); defer { lock.unlock() }
        guard let engine = tts else { return nil }
        guard !text.trimmed.isEmpty else { return nil }
        let count = max(Int(engine.numSpeakers), 1)
        let sid = min(max(speakerId, 0), count - 1)
        let audio = engine.generate(text: text, sid: sid, speed: speed)
        guard audio.audio != nil else { return nil }
        let rate = Int(audio.sampleRate) > 0 ? Int(audio.sampleRate) : modelSampleRate
        let samples = audio.samples
        guard rate > 0, !samples.isEmpty else { return nil }
        return SynthesizedAudio(samples: samples, sampleRate: rate)
    }

    func synthesizeStreaming(
        text: String,
        speed: Float = 1.0,
        speakerId: Int = 0,
        shouldContinue: @escaping () -> Bool,
        onChunk: @escaping ([Float]) -> Int
    ) -> StreamingSynthStats? {
        lock.lock(); defer { lock.unlock() }
        if currentModelType == "kokoro" || currentModelType == "kitten" {
            return nil
        }
        guard let engine = tts else { return nil }
        guard !text.trimmed.isEmpty else { return nil }
        let count = max(Int(engine.numSpeakers), 1)
        let sid = min(max(speakerId, 0), count - 1)

        let context = StreamingContext(shouldContinue: shouldContinue, onChunk: onChunk)
        let arg = Unmanaged.passUnretained(context).toOpaque()
        let callback: TtsCallbackWithArg = { samples, n, arg in
            guard let arg else { return 0 }
            let ctx = Unmanaged<StreamingContext>.fromOpaque(arg).takeUnretainedValue()
            let buffer: [Float] = samples != nil ? Array(UnsafeBufferPointer(start: samples, count: Int(n))) : []
            return Int32(ctx.handle(buffer))
        }

        let audio = engine.generateWithCallbackWithArg(
            text: text, callback: callback, arg: arg, sid: sid, speed: speed
        )

        if context.callbackInvocations == 0 && !context.stoppedEarly {
            if audio.audio != nil, !audio.samples.isEmpty {
                _ = context.handle(audio.samples)
            } else {
                let batch = engine.generate(text: text, sid: sid, speed: speed)
                if batch.audio != nil, !batch.samples.isEmpty {
                    _ = context.handle(batch.samples)
                }
            }
        }

        let rate = (audio.audio != nil && Int(audio.sampleRate) > 0) ? Int(audio.sampleRate) : modelSampleRate
        guard rate > 0 else { return nil }

        if context.totalSamples <= 0 && !context.stoppedEarly {
            let batch = engine.generate(text: text, sid: sid, speed: speed)
            guard batch.audio != nil, !batch.samples.isEmpty else { return nil }
            let result = onChunk(batch.samples)
            context.totalSamples = batch.samples.count
            context.callbackInvocations = 1
            if result == 0 { context.stoppedEarly = true }
        }

        return StreamingSynthStats(
            sampleRate: rate,
            totalSamples: context.totalSamples,
            callbackInvocations: context.callbackInvocations,
            stoppedEarly: context.stoppedEarly
        )
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        releaseLocked()
    }

    /// Permanently marks the engine as shut down and releases the native model.
    /// After this, `loadModel` refuses to construct a new onnxruntime session,
    /// so no native work can start once the process is tearing down.
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        isShutdown = true
        releaseLocked()
    }

    private func releaseLocked() {
        tts = nil
        currentModelPath = nil
        currentModelType = nil
        modelSampleRate = 0
    }

    // MARK: - Config

    private static func createWrapper(
        modelDir: URL,
        modelType: String,
        assets: ResolvedTtsAssets,
        numThreads: Int
    ) -> SherpaOnnxOfflineTtsWrapper {
        let dir = modelDir.path
        func abs(_ name: String) -> String {
            if name.isEmpty || name.hasPrefix("/") { return name }
            return "\(dir)/\(name)"
        }
        let modelPath = "\(dir)/\(assets.modelName)"
        let tokens = "\(dir)/tokens.txt"

        switch modelType {
        case "kitten":
            let kitten = sherpaOnnxOfflineTtsKittenModelConfig(
                model: modelPath,
                voices: abs(assets.voices),
                tokens: tokens,
                dataDir: assets.dataDir
            )
            var config = sherpaOnnxOfflineTtsConfig(
                model: sherpaOnnxOfflineTtsModelConfig(
                    kokoro: sherpaOnnxOfflineTtsKokoroModelConfig(),
                    numThreads: numThreads,
                    debug: 0,
                    provider: "cpu",
                    kitten: kitten
                )
            )
            return withUnsafePointer(to: &config) { SherpaOnnxOfflineTtsWrapper(config: $0) }
        case "kokoro":
            let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
                model: modelPath,
                voices: abs(assets.voices),
                tokens: tokens,
                dataDir: assets.dataDir,
                dictDir: assets.dictDir,
                lexicon: assets.lexicon
            )
            var config = sherpaOnnxOfflineTtsConfig(
                model: sherpaOnnxOfflineTtsModelConfig(
                    kokoro: kokoro,
                    numThreads: numThreads,
                    debug: 0,
                    provider: "cpu"
                ),
                ruleFsts: assets.ruleFsts,
                ruleFars: "",
                maxNumSentences: 1
            )
            return withUnsafePointer(to: &config) { SherpaOnnxOfflineTtsWrapper(config: $0) }
        default:
            let vits = sherpaOnnxOfflineTtsVitsModelConfig(
                model: modelPath,
                lexicon: abs(assets.lexicon),
                tokens: tokens,
                dataDir: assets.dataDir,
                dictDir: assets.dictDir
            )
            var config = sherpaOnnxOfflineTtsConfig(
                model: sherpaOnnxOfflineTtsModelConfig(
                    vits: vits,
                    numThreads: numThreads,
                    debug: 0,
                    provider: "cpu"
                ),
                ruleFsts: assets.ruleFsts,
                ruleFars: "",
                maxNumSentences: 1
            )
            return withUnsafePointer(to: &config) { SherpaOnnxOfflineTtsWrapper(config: $0) }
        }
    }
}

private final class StreamingContext {
    let shouldContinue: () -> Bool
    let onChunk: ([Float]) -> Int
    var callbackInvocations = 0
    var totalSamples = 0
    var stoppedEarly = false

    init(shouldContinue: @escaping () -> Bool, onChunk: @escaping ([Float]) -> Int) {
        self.shouldContinue = shouldContinue
        self.onChunk = onChunk
    }

    func handle(_ samples: [Float]) -> Int {
        if !shouldContinue() {
            stoppedEarly = true
            return 0
        }
        callbackInvocations += 1
        totalSamples += samples.count
        let result = onChunk(samples)
        if result == 0 { stoppedEarly = true }
        return result
    }
}
