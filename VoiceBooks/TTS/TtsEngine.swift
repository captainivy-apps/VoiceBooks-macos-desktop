import Foundation

enum TtsAudioProfile {
    static let targetRms: Float = 0.12
    static let maxPeak: Float = 0.95
    static let minGain: Float = 0.25
    static let maxGain: Float = 10.0
}

struct SynthesizedAudio {
    var samples: [Float]
    var sampleRate: Int

    var isPlayable: Bool { sampleRate > 0 && !samples.isEmpty }
}

struct StreamingSynthStats {
    var sampleRate: Int
    var totalSamples: Int
    var callbackInvocations: Int
    var stoppedEarly: Bool
}

struct TtsVoice {
    var id: String
    var name: String
    var language: String
}

enum TtsAudio {
    /// RMS-targeting loudness normalization with peak limiting.
    static func normalizeForPlayback(
        _ samples: [Float],
        targetRms: Float = TtsAudioProfile.targetRms,
        maxPeak: Float = TtsAudioProfile.maxPeak
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var sumSquares = 0.0
        for sample in samples { sumSquares += Double(sample * sample) }
        let rms = Float((sumSquares / Double(samples.count)).squareRoot())
        guard rms >= 1e-6 else { return samples }

        var gain = targetRms / rms
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample * gain)) }
        if peak > maxPeak { gain *= maxPeak / peak }
        if abs(gain - 1) < 0.02 { return samples }

        gain = min(max(gain, TtsAudioProfile.minGain), TtsAudioProfile.maxGain)
        return samples.map { min(max($0 * gain, -1), 1) }
    }
}

/// Streaming gain that normalizes every emitted chunk independently.
///
/// MeloTTS (and other VITS models configured with `maxNumSentences: 1`) invoke
/// the audio callback once per internal clause/sentence, and those clauses can
/// differ noticeably in loudness (e.g. Chinese vs English). Locking the gain
/// from the first chunk therefore applies an unrepresentative gain to the rest
/// of the sentence, which sounds like the volume jumping up and down. Instead
/// we re-estimate the gain for each chunk, with guards for very short fragments
/// and a short ramp to avoid clicks on gain changes.
final class StreamingGain {
    private var previousGain: Float?

    /// Chunks shorter than this (in ms) are not trusted for a fresh estimate.
    private static let minEstimateMs = 120
    /// Gain is ramped over this many ms at the start of a chunk.
    private static let rampMs = 5

    func reset() { previousGain = nil }

    func applyInPlace(_ samples: inout [Float], sampleRate: Int) {
        guard !samples.isEmpty else { return }
        let estimated = estimateGain(samples, sampleRate: sampleRate)
        let hadPrevious = previousGain != nil
        let startGain = previousGain ?? estimated
        previousGain = estimated

        let rampFrames = hadPrevious ? max(1, sampleRate * Self.rampMs / 1000) : 0
        if abs(estimated - 1) < 0.02, abs(startGain - 1) < 0.02 { return }

        for index in samples.indices {
            let gain: Float
            if index < rampFrames, rampFrames > 0 {
                let t = Float(index) / Float(rampFrames)
                gain = startGain + (estimated - startGain) * t
            } else {
                gain = estimated
            }
            samples[index] = min(max(samples[index] * gain, -1), 1)
        }
    }

    private func estimateGain(_ samples: [Float], sampleRate: Int) -> Float {
        let minFrames = sampleRate > 0 ? sampleRate * Self.minEstimateMs / 1000 : 0
        if samples.count < minFrames, let previous = previousGain { return previous }

        let rms = activeRms(samples, sampleRate: sampleRate)
        guard rms >= 1e-6 else { return previousGain ?? 1 }

        var gain = TtsAudioProfile.targetRms / rms
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample * gain)) }
        if peak > TtsAudioProfile.maxPeak { gain *= TtsAudioProfile.maxPeak / peak }
        return min(max(gain, TtsAudioProfile.minGain), TtsAudioProfile.maxGain)
    }

    /// RMS measured over the active speech span only, ignoring leading/trailing
    /// silence. Clause-sized chunks (MeloTTS) often carry a long trailing
    /// comma pause; including it dilutes the RMS and makes the gain depend on
    /// how much silence the clause happens to contain, which sounds like the
    /// start of a sentence being too quiet or too loud.
    private func activeRms(_ samples: [Float], sampleRate: Int) -> Float {
        let frameLen = max(1, sampleRate / 50) // 20 ms
        let frameCount = (samples.count + frameLen - 1) / frameLen
        guard frameCount > 1 else { return rms(samples, 0, samples.count) }

        var frameRms = [Float](repeating: 0, count: frameCount)
        var maxFrame: Float = 0
        for f in 0..<frameCount {
            let start = f * frameLen
            let end = min(start + frameLen, samples.count)
            let value = rms(samples, start, end)
            frameRms[f] = value
            maxFrame = max(maxFrame, value)
        }
        guard maxFrame >= 1e-6 else { return rms(samples, 0, samples.count) }

        let threshold = maxFrame * 0.1
        var first = 0
        var last = frameCount - 1
        while first < frameCount, frameRms[first] < threshold { first += 1 }
        while last >= 0, frameRms[last] < threshold { last -= 1 }
        guard first <= last else { return rms(samples, 0, samples.count) }

        let startSample = first * frameLen
        let endSample = min((last + 1) * frameLen, samples.count)
        return rms(samples, startSample, endSample)
    }

    private func rms(_ samples: [Float], _ start: Int, _ end: Int) -> Float {
        guard end > start else { return 0 }
        var sumSquares = 0.0
        for index in start..<end { sumSquares += Double(samples[index] * samples[index]) }
        return Float((sumSquares / Double(end - start)).squareRoot())
    }
}
