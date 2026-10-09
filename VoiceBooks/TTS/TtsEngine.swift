import Foundation

enum TtsAudioProfile {
    static let targetRms: Float = 0.12
    static let maxPeak: Float = 0.95
    static let minGain: Float = 0.25
    static let maxGain: Float = 4.0
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

/// Sentence-level streaming gain: lock the RMS estimate from the first chunk.
final class StreamingGain {
    private var lockedGain: Float?

    func reset() { lockedGain = nil }

    func applyInPlace(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        let gain: Float
        if let locked = lockedGain {
            gain = locked
        } else {
            gain = estimateGain(samples)
            lockedGain = gain
        }
        if abs(gain - 1) < 0.02 { return }
        for index in samples.indices {
            samples[index] = min(max(samples[index] * gain, -1), 1)
        }
    }

    private func estimateGain(_ samples: [Float]) -> Float {
        var sumSquares = 0.0
        for sample in samples { sumSquares += Double(sample * sample) }
        let rms = Float((sumSquares / Double(samples.count)).squareRoot())
        guard rms >= 1e-6 else { return 1 }
        var gain = TtsAudioProfile.targetRms / rms
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample * gain)) }
        if peak > TtsAudioProfile.maxPeak { gain *= TtsAudioProfile.maxPeak / peak }
        return min(max(gain, TtsAudioProfile.minGain), TtsAudioProfile.maxGain)
    }
}
