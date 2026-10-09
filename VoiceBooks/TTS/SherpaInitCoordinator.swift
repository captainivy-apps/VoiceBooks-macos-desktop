import Foundation

enum SherpaInitResult {
    case success
    case notDownloaded
    case lowMemory
    case outOfMemory
    case modelLoadFailed
    case error(String)

    var isSuccess: Bool { if case .success = self { return true }; return false }
}

/// Ensures only one Sherpa model load runs at a time and serializes all native
/// calls on a single dedicated thread.
final class SherpaInitCoordinator {
    static let minFreeMB: Int64 = 80

    private let engine: SherpaTtsEngine
    private let queue = DispatchQueue(label: "sherpa-tts")
    private let stateLock = NSLock()
    private var lastInitKey: String?
    private var initTask: Task<SherpaInitResult, Never>?

    init(engine: SherpaTtsEngine) {
        self.engine = engine
    }

    /// Serialize all native Sherpa calls on one thread.
    func withSherpaThread<T>(_ block: () -> T) -> T {
        queue.sync { block() }
    }

    /// Synchronous variant.
    func withSherpaThreadAsync<T>(_ block: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: block()) }
        }
    }

    /// Runs an async block while holding the serial sherpa thread, so native
    /// synthesis calls never overlap.
    func withSherpaThreadAsync<T>(_ block: @escaping () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                let semaphore = DispatchSemaphore(value: 0)
                let box = ResultBox<T>()
                Task {
                    box.value = await block()
                    semaphore.signal()
                }
                semaphore.wait()
                continuation.resume(returning: box.value!)
            }
        }
    }

    /// Hold exclusive access while preview synthesizes so playback cannot release the engine.
    func withExclusiveSynthesis<T>(_ block: @escaping () async -> T) async -> T {
        await withSherpaThreadAsync(block)
    }

    func initKeyFor(_ model: TtsModelEntity?) -> String? {
        guard let model,
              model.downloadState == TtsDownloadState.downloaded.rawValue,
              let localPath = model.localPath else { return nil }
        return "\(model.id):\(model.modelType):\(localPath)"
    }

    func isReadyFor(_ model: TtsModelEntity?) -> Bool {
        guard let key = initKeyFor(model) else { return false }
        return engine.isReady() && lastInitKey == key
    }

    func ensureInitialized(_ model: TtsModelEntity?) async -> SherpaInitResult {
        guard let model,
              model.downloadState == TtsDownloadState.downloaded.rawValue,
              let localPath = model.localPath,
              let initKey = initKeyFor(model) else {
            return .notDownloaded
        }

        if engine.isReady() && lastInitKey == initKey { return .success }
        if engine.isLoadedFor(modelPath: localPath, modelType: model.modelType) {
            lastInitKey = initKey
            return .success
        }

        stateLock.lock()
        if engine.isReady() && lastInitKey == initKey {
            stateLock.unlock()
            return .success
        }
        if engine.isLoadedFor(modelPath: localPath, modelType: model.modelType) {
            lastInitKey = initKey
            stateLock.unlock()
            return .success
        }
        if let existing = initTask {
            stateLock.unlock()
            return await existing.value
        }
        let task = Task<SherpaInitResult, Never> { [weak self] in
            guard let self else { return .modelLoadFailed }
            return await self.loadEngine(model: model, initKey: initKey)
        }
        initTask = task
        stateLock.unlock()

        let result = await task.value

        stateLock.lock()
        if initTask == task { initTask = nil }
        if !result.isSuccess { lastInitKey = nil }
        stateLock.unlock()
        return result
    }

    private func loadEngine(model: TtsModelEntity, initKey: String) async -> SherpaInitResult {
        guard let localPath = model.localPath else { return .notDownloaded }
        guard hasEnoughFreeMemory() else {
            Log.warn("SherpaInitCoordinator", "Skipping Sherpa init: insufficient memory key=\(initKey)")
            return .lowMemory
        }
        let start = DispatchTime.now()
        let loadResult = await withSherpaThreadAsync {
            self.engine.loadModel(modelPath: localPath, modelType: model.modelType)
        }
        let ms = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        if loadResult.isSuccess {
            lastInitKey = initKey
            Log.debug("SherpaInitCoordinator", "engine_load_ms=\(ms) key=\(initKey) success=true")
            return .success
        }
        Log.error("SherpaInitCoordinator", "engine_load_ms=\(ms) key=\(initKey) success=false reason=\(String(describing: loadResult.failure)) detail=\(loadResult.detail ?? "")")
        switch loadResult.failure {
        case .outOfMemory: return .outOfMemory
        default: return .modelLoadFailed
        }
    }

    func invalidate() {
        stateLock.lock()
        lastInitKey = nil
        stateLock.unlock()
    }

    func shutdown() {
        // The serial queue drains naturally; nothing to forcibly stop.
    }

    private func hasEnoughFreeMemory() -> Bool {
        // macOS has no JVM-heap-style cap; the native allocator and OS manage
        // memory pressure, so the headroom gate is a no-op on desktop.
        true
    }
}

private final class ResultBox<T> {
    var value: T?
}
