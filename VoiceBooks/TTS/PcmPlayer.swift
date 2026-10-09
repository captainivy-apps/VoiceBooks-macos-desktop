import Foundation
import AVFoundation

/// Lock-protected float ring buffer for streaming PCM into the audio render callback.
private final class FloatRingBuffer {
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(capacity, 4096)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    /// Writes as many samples as fit; returns the number written.
    func write(_ samples: [Float], offset: Int, length: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let space = capacity - count
        let toWrite = min(length, space)
        guard toWrite > 0 else { return 0 }
        var written = 0
        while written < toWrite {
            storage[writeIndex] = samples[offset + written]
            writeIndex = (writeIndex + 1) % capacity
            written += 1
        }
        count += written
        return written
    }

    /// Fills `count` frames, zero-padding any shortfall.
    func read(into output: UnsafeMutablePointer<Float>, count requested: Int) {
        lock.lock(); defer { lock.unlock() }
        let available = min(requested, count)
        for i in 0..<available {
            output[i] = storage[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        if available < requested {
            for i in available..<requested { output[i] = 0 }
        }
        count -= available
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        count = 0
    }
}

/// Streaming PCM player backed by AVAudioEngine + AVAudioSourceNode.
/// Mirrors the public surface of the Kotlin `PcmStreamPlayer`.
final class PcmPlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var ring: FloatRingBuffer?

    private let lock = NSLock()
    private var trackSampleRate = 0
    private var framesWrittenInternal: Int64 = 0
    private var renderedFramesInternal: Int64 = 0
    private var stopRequested = false

    var framesWritten: Int64 {
        lock.lock(); defer { lock.unlock() }
        return framesWrittenInternal
    }

    var isInitialized: Bool {
        lock.lock(); defer { lock.unlock() }
        return sourceNode != nil && engine.isRunning
    }

    var sampleRate: Int {
        lock.lock(); defer { lock.unlock() }
        return trackSampleRate
    }

    func canAppendContinuous(sampleRate: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sourceNode != nil && trackSampleRate == sampleRate && engine.isRunning
    }

    @discardableResult
    func prepare(sampleRate: Int, appendContinuous: Bool = false) -> Bool {
        guard sampleRate > 0 else { return false }
        lock.lock()
        stopRequested = false
        if appendContinuous, sourceNode != nil, trackSampleRate == sampleRate, engine.isRunning {
            lock.unlock()
            return true
        }
        if sourceNode != nil, trackSampleRate == sampleRate {
            // Reuse the line for a new stream: flush queued audio. Keep the
            // written counter aligned with the rendered head so that
            // `framesWritten` and `playbackHeadFrames` stay consistent.
            engine.pause()
            ring?.clear()
            framesWrittenInternal = renderedFramesInternal
            lock.unlock()
            return true
        }
        lock.unlock()
        return openLine(sampleRate: sampleRate)
    }

    func ensurePlaying() {
        lock.lock()
        let node = sourceNode
        lock.unlock()
        guard node != nil, !engine.isRunning else { return }
        try? engine.start()
    }

    func writeSamples(_ samples: [Float], shouldContinue: () -> Bool = { true }) -> Int {
        guard !samples.isEmpty else { return 0 }
        var offset = 0
        var zeroStreak = 0
        while offset < samples.count {
            if isStopRequested() || !shouldContinue() { return offset }
            guard let ring else { return -1 }
            let written = ring.write(samples, offset: offset, length: samples.count - offset)
            if written == 0 {
                zeroStreak += 1
                if zeroStreak >= 100 {
                    Log.error("PcmPlayer", "write stall zeroWrites=\(zeroStreak) offset=\(offset)")
                    return -1
                }
                Thread.sleep(forTimeInterval: 0.01)
            } else {
                zeroStreak = 0
                offset += written
            }
        }
        lock.lock()
        framesWrittenInternal += Int64(samples.count)
        lock.unlock()
        return samples.count
    }

    func writeSamplesFromOffset(_ samples: [Float], startSample: Int, shouldContinue: () -> Bool = { true }) -> Int {
        if startSample <= 0 { return writeSamples(samples, shouldContinue: shouldContinue) }
        if startSample >= samples.count { return 0 }
        return writeSamples(Array(samples[startSample...]), shouldContinue: shouldContinue)
    }

    func playbackHeadFrames() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return renderedFramesInternal
    }

    func pauseImmediately() {
        engine.pause()
    }

    func signalStopRequested() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    func stopForPauseBlocking() {
        stopAndFlush()
    }

    func stopAndFlush() {
        lock.lock()
        stopRequested = true
        engine.pause()
        ring?.clear()
        // Discarded (unrendered) frames must no longer count as written, so
        // align the written counter with the rendered head.
        framesWrittenInternal = renderedFramesInternal
        stopRequested = false
        lock.unlock()
    }

    func release() {
        lock.lock()
        stopRequested = true
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        sourceNode = nil
        ring = nil
        trackSampleRate = 0
        framesWrittenInternal = 0
        renderedFramesInternal = 0
        stopRequested = false
        lock.unlock()
    }

    // MARK: - Private

    private func isStopRequested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    private func openLine(sampleRate: Int) -> Bool {
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        ring = nil

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            Log.error("PcmPlayer", "Unsupported sample rate: \(sampleRate)")
            return false
        }

        let buffer = FloatRingBuffer(capacity: max(sampleRate * 2, 4096))
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let frames = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if abl.count > 0, let mData = abl[0].mData {
                buffer.read(into: mData.assumingMemoryBound(to: Float.self), count: frames)
            }
            self?.addRenderedFrames(Int64(frames))
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        ring = buffer

        lock.lock()
        trackSampleRate = sampleRate
        framesWrittenInternal = 0
        renderedFramesInternal = 0
        lock.unlock()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.error("PcmPlayer", "Audio engine start failed", error)
            return false
        }
        return true
    }

    private func addRenderedFrames(_ frames: Int64) {
        lock.lock()
        renderedFramesInternal += frames
        lock.unlock()
    }
}
