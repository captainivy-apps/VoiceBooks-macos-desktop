import XCTest
@testable import VoiceBooks

final class StreamingGainTests: XCTestCase {
    private let sampleRate = 16000

    private func constant(_ value: Float, count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }

    private func rms(_ samples: [Float]) -> Float {
        var sumSquares = 0.0
        for sample in samples { sumSquares += Double(sample * sample) }
        return Float((sumSquares / Double(samples.count)).squareRoot())
    }

    func testEachChunkNormalizedToTargetRms() {
        let gain = StreamingGain()
        var quiet = constant(0.05, count: sampleRate / 4)
        var loud = constant(0.2, count: sampleRate / 4)

        gain.applyInPlace(&quiet, sampleRate: sampleRate)
        gain.applyInPlace(&loud, sampleRate: sampleRate)

        XCTAssertEqual(rms(quiet), TtsAudioProfile.targetRms, accuracy: 0.02)
        XCTAssertEqual(rms(loud), TtsAudioProfile.targetRms, accuracy: 0.03)
        XCTAssertLessThan(abs(rms(quiet) - rms(loud)), 0.03)
    }

    func testShortChunkReusesPreviousGain() {
        let gain = StreamingGain()
        var long = constant(0.05, count: sampleRate / 4)
        gain.applyInPlace(&long, sampleRate: sampleRate)

        let previousGain = rms(long) / 0.05
        var short = constant(0.2, count: 100)
        gain.applyInPlace(&short, sampleRate: sampleRate)

        XCTAssertLessThan(short.count, sampleRate * 120 / 1000)
        XCTAssertEqual(Double(rms(short)), Double(0.2 * previousGain), accuracy: 0.01)
    }

    func testSilentChunkKeepsPreviousGain() {
        let gain = StreamingGain()
        var loud = constant(0.05, count: sampleRate / 4)
        gain.applyInPlace(&loud, sampleRate: sampleRate)
        let expectedPeak = loud.max()!

        var silence = constant(0, count: sampleRate / 4)
        gain.applyInPlace(&silence, sampleRate: sampleRate)
        XCTAssertEqual(silence.max() ?? -1, 0)

        var again = constant(0.05, count: sampleRate / 4)
        gain.applyInPlace(&again, sampleRate: sampleRate)
        XCTAssertEqual(again.max()!, expectedPeak, accuracy: 0.001)
    }

    func testAlreadyTargetLevelIsUnchanged() {
        let gain = StreamingGain()
        var balanced = constant(TtsAudioProfile.targetRms, count: sampleRate / 4)
        let original = balanced
        gain.applyInPlace(&balanced, sampleRate: sampleRate)
        XCTAssertEqual(balanced, original)
    }

    func testTrailingSilenceDoesNotDiluteGain() {
        let gain = StreamingGain()
        let speechLen = sampleRate / 5
        var samples = constant(0.05, count: speechLen) + constant(0, count: sampleRate * 4 / 5)

        gain.applyInPlace(&samples, sampleRate: sampleRate)

        let speech = Array(samples[0..<speechLen])
        XCTAssertEqual(rms(speech), TtsAudioProfile.targetRms, accuracy: 0.02)
    }
}
