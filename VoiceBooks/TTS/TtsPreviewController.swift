import Foundation

/// Preview synthesis + benchmark using a dedicated engine, mirroring the Kotlin
/// `TtsPreviewController`.
final class TtsPreviewController {
    private let engine: SherpaTtsEngine
    private let coordinator: SherpaInitCoordinator
    private let player = PcmPlayer()

    private let lock = NSLock()
    private var cancelRequested = false

    private static let maxPreviewTextChars = 400
    private static let kokoroPreviewMaxChars = 80

    init(engine: SherpaTtsEngine, coordinator: SherpaInitCoordinator) {
        self.engine = engine
        self.coordinator = coordinator
    }

    func preview(model: TtsModelEntity, sampleText: String, speakerId: Int) async -> TtsPreviewOutcome {
        guard model.downloadState == TtsDownloadState.downloaded.rawValue, model.localPath != nil else {
            return .failure("模型未下载")
        }
        var target = model
        target.speakerId = speakerId

        let initResult = await coordinator.ensureInitialized(target)
        switch initResult {
        case .success:
            break
        case .notDownloaded:
            return .failure("模型未下载")
        case .lowMemory:
            return .failure("内存不足，无法加载模型（需要约 \(SherpaInitCoordinator.minFreeMB)MB 空闲内存）")
        case .outOfMemory:
            return .failure("内存不足，无法加载模型")
        case .modelLoadFailed:
            return .failure("模型加载失败")
        case .error(let detail):
            return .failure(detail.isEmpty ? "模型加载失败" : detail)
        }

        let effectiveSpeakerId = await coordinator.withSherpaThreadAsync { self.engine.resolveSpeakerId(speakerId) }
        let outcome = await coordinator.withSherpaThreadAsync {
            await self.synthesizeAndPlay(model: model, sampleText: sampleText, speakerId: effectiveSpeakerId)
        }
        engine.release()
        coordinator.invalidate()
        return outcome
    }

    func stopPlayback() {
        lock.lock(); cancelRequested = true; lock.unlock()
        player.stopAndFlush()
    }

    private func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    private func synthesizeAndPlay(model: TtsModelEntity, sampleText: String, speakerId: Int) async -> TtsPreviewOutcome {
        let batchOnly = TtsAssetResolver.requiresBatchSynthesis(model.modelType)
        let maxChars = batchOnly ? Self.kokoroPreviewMaxChars : Self.maxPreviewTextChars
        lock.lock(); cancelRequested = false; lock.unlock()
        player.release()

        let shouldContinue = { !self.isCancelled() }
        let textChunks = TtsTextChunker.chunk(sampleText, maxChars: maxChars)
        var audioChunks: [(samples: [Float], rate: Int)] = []
        let start = Self.nowMs()

        for textChunk in textChunks {
            if !shouldContinue() { break }
            var chunk: (samples: [Float], rate: Int)?
            if !batchOnly {
                chunk = synthesizeStreaming(textChunk: textChunk, speakerId: speakerId, shouldContinue: shouldContinue)
            }
            if chunk == nil {
                chunk = synthesizeBatch(textChunk: textChunk, speakerId: speakerId, normalizeBatch: batchOnly)
            }
            if let chunk { audioChunks.append(chunk) }
        }
        let synthesisMs = Self.nowMs() - start

        if !shouldContinue() {
            player.stopAndFlush()
            return .cancelled
        }
        guard !audioChunks.isEmpty else {
            player.release()
            return .failure("合成失败")
        }

        let totalSamples = audioChunks.reduce(0) { $0 + $1.samples.count }
        var sampleRate = 0
        let gain = StreamingGain()
        var playbackStarted = false
        var framesBefore: Int64 = 0

        for chunk in audioChunks {
            if !shouldContinue() { break }
            if sampleRate <= 0 {
                let rate = chunk.rate
                if rate <= 0 || !player.prepare(sampleRate: rate) { continue }
                sampleRate = rate
            }
            var samples = chunk.samples
            gain.applyInPlace(&samples)
            if !playbackStarted {
                player.ensurePlaying()
                framesBefore = player.framesWritten
                playbackStarted = true
            }
            _ = player.writeSamples(samples, shouldContinue: shouldContinue)
        }

        if sampleRate <= 0 {
            sampleRate = audioChunks.first?.rate ?? engine.sampleRate()
        }
        if playbackStarted, sampleRate > 0 {
            await awaitPlaybackComplete(
                framesBefore: framesBefore,
                framesEnd: player.framesWritten,
                sampleRate: sampleRate,
                shouldContinue: shouldContinue
            )
        }
        player.release()

        if !shouldContinue() { return .cancelled }
        guard totalSamples > 0, sampleRate > 0 else { return .failure("合成失败") }

        let audioDurationMs = Int64(totalSamples) * 1000 / Int64(sampleRate)
        let rtf = audioDurationMs > 0 ? Float(synthesisMs) / Float(audioDurationMs) : 0
        return .success(TtsModelBenchmark(
            modelId: model.id, speakerId: speakerId, synthesisMs: synthesisMs,
            audioDurationMs: audioDurationMs, rtf: rtf, sampleRate: sampleRate,
            benchmarkedAt: Self.nowMs()
        ))
    }

    private func synthesizeBatch(textChunk: String, speakerId: Int, normalizeBatch: Bool) -> (samples: [Float], rate: Int)? {
        guard let batch = engine.synthesize(text: textChunk, speed: 1.0, speakerId: speakerId), batch.isPlayable else { return nil }
        var samples = batch.samples
        if normalizeBatch { samples = TtsAudio.normalizeForPlayback(samples) }
        let rate = batch.sampleRate > 0 ? batch.sampleRate : engine.sampleRate()
        guard rate > 0 else { return nil }
        return (samples, rate)
    }

    private func synthesizeStreaming(textChunk: String, speakerId: Int, shouldContinue: @escaping () -> Bool) -> (samples: [Float], rate: Int)? {
        var pcmChunks: [[Float]] = []
        let stats = engine.synthesizeStreaming(
            text: textChunk, speed: 1.0, speakerId: speakerId,
            shouldContinue: shouldContinue,
            onChunk: { pcm in
                if !shouldContinue() { return 0 }
                pcmChunks.append(pcm)
                return 1
            }
        )
        guard let stats, !pcmChunks.isEmpty else { return nil }
        let rate = stats.sampleRate > 0 ? stats.sampleRate : engine.sampleRate()
        guard rate > 0 else { return nil }
        let merged = pcmChunks.flatMap { $0 }
        guard !merged.isEmpty else { return nil }
        return (merged, rate)
    }

    private func awaitPlaybackComplete(framesBefore: Int64, framesEnd: Int64, sampleRate: Int, shouldContinue: () -> Bool) async {
        guard framesEnd > framesBefore, sampleRate > 0 else { return }
        let frameCount = framesEnd - framesBefore
        let expectedMs = frameCount * 1000 / Int64(sampleRate)
        let start = Self.nowMs()
        let deadline = start + expectedMs + 175
        let timeout = deadline + 500
        while shouldContinue() {
            let now = Self.nowMs()
            if now >= timeout { break }
            if player.playbackHeadFrames() >= framesEnd, now >= deadline { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
