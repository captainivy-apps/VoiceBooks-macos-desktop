import Foundation

private final class AtomicBool {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    @discardableResult
    func compareAndSet(_ expected: Bool, _ newValue: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value == expected { value = newValue; return true }
        return false
    }
}

private enum SherpaPlayResult {
    case completed
    case interrupted
    case failed(userMessage: String, logDetail: String)
}

private struct PreloadedSentence {
    let pcmChunks: [[Float]]
    let sampleRate: Int
    let synthesisMs: Int64

    var isPlayable: Bool {
        !pcmChunks.isEmpty && sampleRate > 0 && pcmChunks.allSatisfy { !$0.isEmpty }
    }
}

private struct SubtitleUpdate {
    let index: Int
    let text: String
    let totalSentences: Int
}

private final class StreamChunkWriteState {
    var skipMs: Int64
    var notifyStartup: Bool
    var subtitle: SubtitleUpdate?
    let sentenceIndex: Int
    let session: Int
    var playbackStarted = false

    init(skipMs: Int64, notifyStartup: Bool, subtitle: SubtitleUpdate?, sentenceIndex: Int, session: Int) {
        self.skipMs = skipMs
        self.notifyStartup = notifyStartup
        self.subtitle = subtitle
        self.sentenceIndex = sentenceIndex
        self.session = session
    }
}

/// Desktop playback engine. Ported from the Kotlin `PlaybackEngine`.
final class PlaybackEngine {
    private let bookRepository: BookRepository
    private let ttsRepository: TtsRepository
    private let sherpaEngine: SherpaTtsEngine
    private let sherpaInitCoordinator: SherpaInitCoordinator
    private let playbackSessionStore: PlaybackSessionStore

    private let pcmPlayer = PcmPlayer()
    private let wakeLock = PlaybackWakeLock()

    private let stateLock = NSRecursiveLock()
    private var toastGeneration = 0
    private var playbackSession = 0
    private var seekGeneration = 0

    private var sentences: [SentenceIndexEntity] = []
    private var currentIndex = 0
    private var positionInSentenceMs: Int64 = 0
    private var sentenceFramesBase: Int64 = 0
    private var sentenceSampleRate = 0
    private var audioTrackNeedsReset = false
    private var playbackSpeed: Float = 1.0
    private var bookId = ""
    private var bookTitle = ""
    private let isPlaying = AtomicBool(false)

    private var playbackJob: Task<Void, Never>?
    private var playFromCurrentJob: Task<Void, Never>?
    private var drainedPlaybackJob: Task<Void, Never>?
    private var sleepTimerJob: Task<Void, Never>?
    private var sleepUntilEndOfBook = false
    private var speakerId = 0
    private var activeTtsKey: String?

    private var preloadedAudio: [Int: PreloadedSentence] = [:]
    private var prefetchedText: [Int: String] = [:]
    private var prefetchTextJobs: [Int: Task<Void, Never>] = [:]
    private var preloadJobs: [Int: Task<Void, Never>] = [:]
    private var startupToastPending = false
    private var preloadsEnabled = false
    private var startPlaybackJob: Task<Void, Never>?
    private var pauseFinalizeJob: Task<Void, Never>?
    private var lastSentenceEndMs: Int64 = 0
    private var nextPreloadIndex = -1

    private let pauseInFlight = AtomicBool(false)
    private let resumeInFlight = AtomicBool(false)
    private let seekInFlight = AtomicBool(false)

    private var resumeStartSignal: (() -> Void)?

    private var sherpaSpeed: Float { min(max(playbackSpeed, Self.minSherpaSpeed), Self.maxSherpaSpeed) }

    private static let maxSherpaTextChars = 400
    private static let minSherpaSpeed: Float = 0.5
    private static let maxSherpaSpeed: Float = 3.0
    private static let maxPreloadAhead = 8
    private static let initRetryDelayMs: Int64 = 200
    private static let preloadAwaitPolls = 40
    private static let preloadAwaitPollMs: UInt64 = 25
    private static let seekAudioStopTimeoutMs: Int64 = 1000
    private static let pauseFinalizeAwaitTimeoutMs: Int64 = 1500
    private static let resumeLoopStartTimeoutMs: Int64 = 2000

    init(
        bookRepository: BookRepository,
        ttsRepository: TtsRepository,
        sherpaEngine: SherpaTtsEngine,
        sherpaInitCoordinator: SherpaInitCoordinator,
        playbackSessionStore: PlaybackSessionStore
    ) {
        self.bookRepository = bookRepository
        self.ttsRepository = ttsRepository
        self.sherpaEngine = sherpaEngine
        self.sherpaInitCoordinator = sherpaInitCoordinator
        self.playbackSessionStore = playbackSessionStore

        PlaybackController.shared.immediatePauseHandler = { [weak self] in
            self?.pausePlayback()
        }
        PlaybackController.shared.immediateResumeHandler = { [weak self] in
            self?.resumePlayback()
        }
        playbackSpeed = AppSettings.playbackSpeed
        PlaybackController.shared.update { $0.copy(speed: self.playbackSpeed) }
    }

    // MARK: - Public API

    func play(bookId: String) { launchStartPlayback(bookId) }
    func pause() { pausePlayback() }
    func resume() { resumePlayback() }

    func toggle(bookId: String?) {
        if isPlaying.get() {
            pausePlayback()
        } else if currentSentencesEmpty() {
            if let bookId { launchStartPlayback(bookId) }
        } else {
            resumePlayback()
        }
    }

    func rewind() { skipSentence(-1) }
    func forward() { skipSentence(1) }
    func stop() { stopPlayback() }

    func setSpeed(_ speed: Float) {
        stateLock.lock(); playbackSpeed = speed; stateLock.unlock()
        PlaybackController.shared.update { $0.copy(speed: speed) }
        applySpeedChange()
    }

    func reloadTts() { Task { await reloadTtsEngine() } }
    func syncTtsEngineAsync() { Task { await syncTtsEngine() } }
    func prepareForPreview() { prepareForTtsPreview() }

    func setSleepTimer(endOfBook: Bool, minutes: Int) {
        stateLock.lock(); sleepUntilEndOfBook = endOfBook; stateLock.unlock()
        scheduleSleepTimer(minutes: minutes, untilEnd: endOfBook)
    }

    func seekTo(index: Int, resume: Bool) { seekToSentenceImmediate(index: index, resume: resume) }
    func isRunning() -> Bool { isPlaying.get() || !currentBookId().isEmpty }

    func recoverIfNeeded() {
        AppSettings.clearSleepTimer()
        clearSleepTimer(persist: false)
        tryRecoverPlaybackIfNeeded()
    }

    func shutdown() {
        PlaybackController.shared.immediatePauseHandler = nil
        PlaybackController.shared.immediateResumeHandler = nil
        isPlaying.set(false)
        stateLock.lock()
        playbackSession += 1
        playbackJob?.cancel()
        playbackJob = nil
        playFromCurrentJob?.cancel()
        playFromCurrentJob = nil
        startPlaybackJob?.cancel()
        startPlaybackJob = nil
        pauseFinalizeJob?.cancel()
        pauseFinalizeJob = nil
        sleepTimerJob?.cancel()
        sleepTimerJob = nil
        preloadsEnabled = false
        stateLock.unlock()
        pcmPlayer.signalStopRequested()
        pcmPlayer.pauseImmediately()
        cancelPreloads()
        pcmPlayer.release()
    }

    // MARK: - Helpers (state access)

    private func currentBookId() -> String { stateLock.lock(); defer { stateLock.unlock() }; return bookId }
    private func currentSentencesEmpty() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return sentences.isEmpty }
    private func currentSession() -> Int { stateLock.lock(); defer { stateLock.unlock() }; return playbackSession }
    private func bumpSession() -> Int { stateLock.lock(); defer { stateLock.unlock() }; playbackSession += 1; return playbackSession }
    private func setLoadingStage(_ stage: TtsLoadingStage) {
        PlaybackController.shared.update { state in
            var next = state
            next.loadingStage = stage
            next.lastError = nil
            return next
        }
    }

    // MARK: - Startup / recovery

    private func launchStartPlayback(_ id: String, recover: Bool = false) {
        stateLock.lock()
        if !recover {
            startPlaybackJob?.cancel()
            startPlaybackJob = nil
        } else if startPlaybackJob != nil {
            stateLock.unlock()
            return
        }
        if !recover, id == bookId, playbackJob != nil || playFromCurrentJob != nil {
            stateLock.unlock()
            return
        }
        startPlaybackJob?.cancel()
        startPlaybackJob = Task { [weak self] in
            guard let self else { return }
            await self.startPlayback(id: id, recover: recover)
            self.stateLock.lock(); self.startPlaybackJob = nil; self.stateLock.unlock()
        }
        stateLock.unlock()
    }

    private func tryRecoverPlaybackIfNeeded() {
        stateLock.lock()
        let idle = bookId.isEmpty && startPlaybackJob == nil && !isPlaying.get()
        stateLock.unlock()
        guard idle, let session = playbackSessionStore.load(), session.shouldResumeOnRestart else { return }
        launchStartPlayback(session.bookId, recover: true)
    }

    private func persistPlaybackSession(shouldResumeOnRestart: Bool) {
        let id = currentBookId()
        guard !id.isEmpty else { return }
        playbackSessionStore.save(bookId: id, shouldResumeOnRestart: shouldResumeOnRestart)
    }

    private func startPlayback(id: String, recover: Bool = false) async {
        invalidateToastSession()
        stateLock.lock(); startupToastPending = !recover; stateLock.unlock()
        setLoadingStage(.loadingBook)
        if recover { showTtsMessage(PlaybackMessages.recovering) } else { showTtsToast(PlaybackMessages.loadingBook) }

        guard let book = try? await bookRepository.getBook(id) else {
            stateLock.lock(); startupToastPending = false; stateLock.unlock()
            abortStartup()
            return
        }
        let loadedSentences = (try? await bookRepository.getSentences(id)) ?? []
        stateLock.lock()
        bookId = id
        bookTitle = book.title
        sentences = loadedSentences
        stateLock.unlock()

        guard !loadedSentences.isEmpty else {
            stateLock.lock(); startupToastPending = false; stateLock.unlock()
            abortStartup()
            return
        }

        updateControllerState(title: book.title, author: book.author, coverPath: book.coverPath, state: .loading)

        let progress = try? await bookRepository.getProgress(id)
        stateLock.lock()
        currentIndex = progress?.currentSentenceIndex ?? 0
        positionInSentenceMs = progress?.positionInSentenceMs ?? 0
        stateLock.unlock()
        _ = sanitizeCurrentSentencePosition()

        playbackSpeed = AppSettings.playbackSpeed
        if sleepTimerJob == nil {
            stateLock.lock()
            sleepUntilEndOfBook = AppSettings.sleepUntilEnd
            let untilEnd = sleepUntilEndOfBook
            stateLock.unlock()
            PlaybackController.shared.update { $0.copy(sleepTimerRemainingMs: 0, sleepUntilEndOfBook: untilEnd) }
        }

        let defaultModel = try? await ttsRepository.getDefaultModel()
        stateLock.lock(); preloadsEnabled = false; stateLock.unlock()

        let initResult = await awaitReinitializeTts(defaultModel: defaultModel ?? nil)
        if initResult.isSuccess {
            stateLock.lock(); preloadsEnabled = true; stateLock.unlock()
            prefetchTextWindow(fromCurrentIndex: currentIndexSnapshot())
            await kickoffStartupPreloads()
            _ = sanitizeCurrentSentencePosition()
            _ = advanceIfSentenceAlreadyFinished()
            persistPlaybackSession(shouldResumeOnRestart: true)
            startPlaybackPipeline(forceRestart: false)
        } else {
            failPlayback(initResult.userMessage)
        }
    }

    private func currentIndexSnapshot() -> Int { stateLock.lock(); defer { stateLock.unlock() }; return currentIndex }

    private func markOutputtingAudioIfStartup() {
        stateLock.lock(); let pending = startupToastPending; stateLock.unlock()
        guard pending else { return }
        PlaybackController.shared.update { state in
            state.loadingStage == .outputtingAudio ? state : state.copy(loadingStage: .outputtingAudio)
        }
    }

    private func kickoffStartupPreloads() async {
        guard sherpaEngine.isReady(), isPreloadsEnabled() else { return }
        preloadCurrentNow(currentIndexSnapshot())
        ensureSequentialPreload(startIndex: currentIndexSnapshot() + 1)
        if !hasPreloadedAudio(currentIndexSnapshot()) {
            setLoadingStage(.synthesizing)
        }
        await awaitPreload(index: currentIndexSnapshot())
    }

    private func isPreloadsEnabled() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return preloadsEnabled }

    // MARK: - Failure / messaging

    private func failPlayback(_ message: String) {
        stateLock.lock()
        startupToastPending = false
        isPlaying.set(false)
        playFromCurrentJob?.cancel(); playFromCurrentJob = nil
        drainedPlaybackJob = nil
        playbackJob?.cancel(); playbackJob = nil
        stateLock.unlock()
        wakeLock.release()
        persistPlaybackSession(shouldResumeOnRestart: false)
        invalidateToastSession()
        cancelPreloads()
        releaseAudioTrack()
        Log.error("PlaybackEngine", message)
        PlaybackController.shared.update {
            $0.copy(playbackState: .error, loadingStage: .none, lastError: message)
        }
        showTtsMessage(message)
    }

    private func handlePlaybackFailure(_ error: Error) {
        if error is CancellationError { return }
        stateLock.lock(); startupToastPending = false; isPlaying.set(false); playbackJob?.cancel(); stateLock.unlock()
        cancelPreloads()
        failPlayback((error as NSError).localizedDescription.isEmpty ? PlaybackMessages.playbackFailedGeneric : (error as NSError).localizedDescription)
    }

    private func invalidateToastSession() { stateLock.lock(); toastGeneration += 1; stateLock.unlock() }
    private func showTtsToast(_ message: String) { showTtsMessage(message, gated: true) }

    private func showTtsMessage(_ message: String, gated: Bool = false) {
        stateLock.lock(); let generation = toastGeneration; stateLock.unlock()
        Task { @MainActor in
            if gated {
                self.stateLock.lock(); let current = self.toastGeneration; self.stateLock.unlock()
                if current != generation { return }
            }
            AppNotifier.shared.show(message, long: true)
        }
    }

    private func finishStartupToast() {
        stateLock.lock()
        guard startupToastPending else { stateLock.unlock(); return }
        startupToastPending = false
        let generation = toastGeneration
        stateLock.unlock()
        Task { @MainActor in
            self.stateLock.lock(); let current = self.toastGeneration; self.stateLock.unlock()
            if current != generation { return }
            AppNotifier.shared.show(PlaybackMessages.startupPlaying, long: false)
        }
    }

    private func updateControllerState(title: String, author: String, coverPath: String?, state: PlaybackState) {
        stateLock.lock()
        let id = bookId
        let total = sentences.count
        let index = currentIndex
        let preview = sentences.indices.contains(index) ? sentences[index].textPreview : ""
        let pos = positionInSentenceMs
        let speed = playbackSpeed
        let untilEnd = sleepUntilEndOfBook
        stateLock.unlock()
        PlaybackController.shared.update { current in
            var next = current
            next.bookId = id
            next.bookTitle = title
            next.bookAuthor = author
            next.coverPath = coverPath
            next.totalSentences = total
            next.currentSentenceIndex = index
            next.currentSentenceText = preview
            next.playbackState = state
            next.speed = speed
            next.positionInSentenceMs = pos
            next.sleepUntilEndOfBook = untilEnd
            return next
        }
    }

    // MARK: - Audio control

    private func submitAudioStop(snapshotPosition: Bool) {
        stateLock.lock(); audioTrackNeedsReset = true; stateLock.unlock()
        pcmPlayer.pauseImmediately()
        if snapshotPosition { snapshotPausePosition() }
        pcmPlayer.stopForPauseBlocking()
    }

    private func snapshotPausePosition() {
        stateLock.lock()
        let base = sentenceFramesBase
        let fallbackRate = sentenceSampleRate
        stateLock.unlock()
        guard base > 0 else { return }
        let rate = pcmPlayer.sampleRate > 0 ? pcmPlayer.sampleRate : fallbackRate
        guard rate > 0 else { return }
        let head = pcmPlayer.playbackHeadFrames()
        let playedMs = max(head - base, 0) * 1000 / Int64(rate)
        let normalized = SentencePlaybackPosition.sanitizePositionForSentence(
            playedMs, durationMs: peekSentenceDurationMs(currentIndexSnapshot())
        )
        stateLock.lock()
        if normalized > positionInSentenceMs {
            positionInSentenceMs = normalized
            let value = normalized
            stateLock.unlock()
            PlaybackController.shared.update { $0.copy(positionInSentenceMs: value) }
        } else {
            stateLock.unlock()
        }
    }

    private func preparePcmPlayer(sampleRate: Int) -> Bool {
        stateLock.lock()
        let needsReset = audioTrackNeedsReset
        stateLock.unlock()
        let append = !needsReset && pcmPlayer.canAppendContinuous(sampleRate: sampleRate)
        let ok = pcmPlayer.prepare(sampleRate: sampleRate, appendContinuous: append)
        if ok {
            stateLock.lock()
            if audioTrackNeedsReset { audioTrackNeedsReset = false }
            stateLock.unlock()
        }
        return ok
    }

    private func markSentencePlaybackStart(sampleRate: Int) {
        stateLock.lock()
        sentenceFramesBase = pcmPlayer.framesWritten
        sentenceSampleRate = sampleRate
        stateLock.unlock()
    }

    private func invalidateSentenceFrameSnapshot() {
        stateLock.lock(); sentenceFramesBase = 0; sentenceSampleRate = 0; stateLock.unlock()
    }

    private func interruptPlayback() -> Task<Void, Never>? {
        stateLock.lock()
        playFromCurrentJob?.cancel(); playFromCurrentJob = nil
        drainedPlaybackJob = nil
        playbackSession += 1
        let previous = playbackJob
        previous?.cancel(); playbackJob = nil
        stateLock.unlock()
        pcmPlayer.signalStopRequested()
        pcmPlayer.pauseImmediately()
        submitAudioStop(snapshotPosition: false)
        return previous
    }

    private func awaitPlaybackDrain(_ previousJob: Task<Void, Never>?) async {
        previousJob?.cancel()
        _ = await sherpaInitCoordinator.withSherpaThreadAsync { }
    }

    private func restartPlaybackFromCurrent(clearPreloads: Bool = false) {
        if clearPreloads { cancelPreloads() }
        playFromCurrent(forceRestart: true)
    }

    private func schedulePlaybackRecoveryIfNeeded() {
        stateLock.lock()
        let shouldRecover = isPlaying.get() && currentIndex < sentences.count
        let busy = playbackJob != nil || playFromCurrentJob != nil
        stateLock.unlock()
        guard shouldRecover, !busy else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.stateLock.lock()
            let stillNeeded = self.isPlaying.get() && self.currentIndex < self.sentences.count
            let stillBusy = self.playbackJob != nil || self.playFromCurrentJob != nil
            self.stateLock.unlock()
            guard stillNeeded, !stillBusy else { return }
            self.playFromCurrent()
        }
    }

    private func stopAudioTrackForGap() { submitAudioStop(snapshotPosition: false) }

    private func playFromCurrent(forceRestart: Bool = false) {
        stateLock.lock()
        playFromCurrentJob?.cancel()
        let zombie = drainedPlaybackJob
        drainedPlaybackJob = nil
        let previous: Task<Void, Never>?
        if forceRestart || playbackJob != nil {
            stateLock.unlock()
            previous = interruptPlayback()
        } else {
            let needsStop = pcmPlayer.isInitialized || audioTrackNeedsReset
            stateLock.unlock()
            if needsStop {
                pcmPlayer.signalStopRequested()
                submitAudioStop(snapshotPosition: false)
            }
            previous = nil
        }

        let job = Task { [weak self] in
            guard let self else { return }
            let restartSession = self.currentSession()
            self.pcmPlayer.pauseImmediately()
            await self.awaitPlaybackDrain(previous)
            await self.awaitPlaybackDrain(zombie)
            if Task.isCancelled { self.signalResumeLoopStarted(); return }
            if restartSession != self.currentSession() { self.abortPlayFromCurrent(reason: "session_mismatch"); return }
            if !self.isPlaying.get(), PlaybackController.shared.snapshot.playbackState == .paused {
                self.abortPlayFromCurrent(reason: "paused"); return
            }
            self.stateLock.lock(); self.lastSentenceEndMs = 0; self.stateLock.unlock()
            self.startPlaybackLoop()
        }
        stateLock.lock()
        playFromCurrentJob = job
        stateLock.unlock()
    }

    private func startPlaybackLoop() {
        wakeLock.acquire()
        persistPlaybackSession(shouldResumeOnRestart: true)
        stateLock.lock()
        playbackJob?.cancel()
        let loopSession = playbackSession
        playbackJob = Task { [weak self] in
            guard let self else { return }
            await self.runPlaybackLoop(loopSession: loopSession)
        }
        stateLock.unlock()
    }

    private func runPlaybackLoop(loopSession: Int) async {
        if !isPlaying.get() { signalResumeLoopStarted(); return }
        signalResumeLoopStarted()
        if sherpaEngine.isReady() {
            stateLock.lock(); preloadsEnabled = true; stateLock.unlock()
            prefetchTextWindow(fromCurrentIndex: currentIndexSnapshot())
            ensureSequentialPreload(startIndex: currentIndexSnapshot() + 1)
        }

        while !Task.isCancelled, currentIndexSnapshot() < sentencesCount(), isPlaying.get() {
            if loopSession != currentSession() {
                schedulePlaybackRecoveryIfNeeded()
                return
            }
            if advanceIfSentenceAlreadyFinished() {
                if currentIndexSnapshot() >= sentencesCount() {
                    pausePlayback()
                    PlaybackController.shared.update { $0.copy(playbackState: .stopped) }
                    return
                }
                continue
            }
            let index = currentIndexSnapshot()
            let sentence: SentenceIndexEntity
            stateLock.lock(); sentence = sentences[index]; stateLock.unlock()

            stateLock.lock(); let isFirstSentence = startupToastPending; stateLock.unlock()
            if isFirstSentence {
                setLoadingStage(.readingText)
                showTtsToast(PlaybackMessages.startupReadingText)
            }

            var text = await loadSentenceText(sentence, index: index)
            guard let adapted = await adaptTextForCurrentModel(raw: text) else {
                stateLock.lock()
                positionInSentenceMs = 0
                currentIndex += 1
                stateLock.unlock()
                invalidateSentenceFrameSnapshot()
                saveProgressAsync()
                stateLock.lock(); lastSentenceEndMs = Self.nowMs(); stateLock.unlock()
                continue
            }
            text = adapted

            var cached = takePreloaded(index: index)
            let initialCacheHit = cached != nil
            if isPreloadsEnabled() && initialCacheHit {
                schedulePreloadWindow(fromCurrentIndex: index)
            } else if isPreloadsEnabled() {
                prefetchTextWindow(fromCurrentIndex: index)
                ensureSequentialPreload(startIndex: index + 1)
            }

            if cached == nil {
                stopAudioTrackForGap()
                cancelCompetingPreloads(urgentIndex: index)
                if preloadJobs[index] != nil {
                    await awaitPreload(index: index)
                    cached = takePreloaded(index: index)
                }
            }

            if cached == nil, isFirstSentence {
                setLoadingStage(.synthesizing)
                showTtsToast(PlaybackMessages.startupSynthesizing)
            }

            let result: SherpaPlayResult
            if let cached, cached.isPlayable {
                result = await playCachedSherpa(cached: cached, startMs: positionInSentenceMsSnapshot(), notifyStartup: isFirstSentence, sentenceIndex: index, subtitleText: text)
            } else {
                result = await streamSynthAndPlay(text: text, startMs: positionInSentenceMsSnapshot(), notifyStartup: isFirstSentence, sentenceIndex: index)
            }

            switch result {
            case .completed:
                stateLock.lock(); positionInSentenceMs = 0; stateLock.unlock()
                if !hasPreloadedAudio(index + 1), index + 1 < sentencesCount() {
                    ensureSequentialPreload(startIndex: index + 1)
                }
                schedulePreloadsAfterSentence()
                stateLock.lock()
                lastSentenceEndMs = Self.nowMs()
                currentIndex += 1
                stateLock.unlock()
                invalidateSentenceFrameSnapshot()
                syncPlaybackIndexToController()
                saveProgressAsync()
                stateLock.lock(); let untilEnd = sleepUntilEndOfBook; stateLock.unlock()
                if untilEnd, currentIndexSnapshot() >= sentencesCount() {
                    pausePlayback()
                    clearSleepTimer(persist: true)
                    return
                }
            case .interrupted:
                if loopSession == currentSession() { isPlaying.set(false) }
                return
            case .failed(let userMessage, let logDetail):
                if Task.isCancelled || !isPlaying.get() || loopSession != currentSession() { return }
                failPlayback(userMessage)
                Log.error("PlaybackEngine", logDetail)
                return
            }
        }

        if currentIndexSnapshot() >= sentencesCount() {
            pausePlayback()
            PlaybackController.shared.update { $0.copy(playbackState: .stopped) }
        } else if isPlaying.get() {
            schedulePlaybackRecoveryIfNeeded()
        } else if PlaybackController.shared.snapshot.playbackState == .playing, currentIndexSnapshot() < sentencesCount() {
            _ = sanitizeCurrentSentencePosition()
            let advanced = advanceIfSentenceAlreadyFinished()
            if advanced, currentIndexSnapshot() >= sentencesCount() {
                pausePlayback()
                PlaybackController.shared.update { $0.copy(playbackState: .stopped) }
            } else {
                PlaybackController.shared.update { $0.copy(playbackState: .paused, loadingStage: .none) }
            }
        }
    }

    private func sentencesCount() -> Int { stateLock.lock(); defer { stateLock.unlock() }; return sentences.count }
    private func positionInSentenceMsSnapshot() -> Int64 { stateLock.lock(); defer { stateLock.unlock() }; return positionInSentenceMs }

    // MARK: - Text

    private func loadSentenceText(_ sentence: SentenceIndexEntity, index: Int) async -> String {
        stateLock.lock(); let prefetched = prefetchedText.removeValue(forKey: index); stateLock.unlock()
        if let prefetched { return prefetched }
        return await readSentenceTextFromDisk(sentence)
    }

    private func adaptTextForCurrentModel(raw: String) async -> String? {
        let model = try? await ttsRepository.getDefaultModel()
        guard let model = model ?? nil else {
            let trimmed = raw.trimmed
            return trimmed.isEmpty ? nil : trimmed
        }
        return TtsTextAdapter.adaptForModel(raw, modelLanguage: model.language)
    }

    private func readSentenceTextFromDisk(_ sentence: SentenceIndexEntity) async -> String {
        guard let book = try? await bookRepository.getBook(currentBookId()), !book.textPath.isEmpty else {
            return sentence.textPreview
        }
        let text = await bookRepository.readSentenceText(textPath: book.textPath, byteOffsetStart: sentence.byteOffsetStart, byteOffsetEnd: sentence.byteOffsetEnd)
        return text.isEmpty ? sentence.textPreview : text
    }

    private func prefetchSentenceText(index: Int) {
        guard index >= 0, index < sentencesCount() else { return }
        stateLock.lock()
        let exists = prefetchedText[index] != nil || prefetchTextJobs[index] != nil
        stateLock.unlock()
        guard !exists else { return }
        let job = Task { [weak self] in
            guard let self else { return }
            let text = await self.readSentenceTextFromDisk(self.sentenceAt(index))
            self.stateLock.lock()
            if self.prefetchedText[index] == nil { self.prefetchedText[index] = text }
            self.prefetchTextJobs.removeValue(forKey: index)
            self.stateLock.unlock()
        }
        stateLock.lock(); prefetchTextJobs[index] = job; stateLock.unlock()
    }

    private func sentenceAt(_ index: Int) -> SentenceIndexEntity {
        stateLock.lock(); defer { stateLock.unlock() }
        return sentences[index]
    }

    private func prefetchTextWindow(fromCurrentIndex: Int) {
        for offset in 0...Self.maxPreloadAhead {
            prefetchSentenceText(index: fromCurrentIndex + offset)
        }
    }

    // MARK: - Preload cache

    private func takePreloaded(index: Int) -> PreloadedSentence? {
        stateLock.lock(); defer { stateLock.unlock() }
        return preloadedAudio.removeValue(forKey: index)
    }

    private func hasPreloadedAudio(_ index: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return preloadedAudio[index] != nil
    }

    private func preloadJobSnapshot(_ index: Int) -> Task<Void, Never>? {
        stateLock.lock(); defer { stateLock.unlock() }
        return preloadJobs[index]
    }

    private func awaitPreload(index: Int) async {
        if hasPreloadedAudio(index) { return }
        cancelCompetingPreloads(urgentIndex: index)
        preloadCurrentNow(index)

        // Join the in-flight preload (do NOT cancel it) — mirrors the Kotlin await.
        if let existing = preloadJobSnapshot(index) {
            await existing.value
            if hasPreloadedAudio(index) { return }
        }

        ensureSequentialPreload(startIndex: index)
        preloadCurrentNow(index)
        for poll in 0..<Self.preloadAwaitPolls {
            if hasPreloadedAudio(index) { return }
            if let job = preloadJobSnapshot(index) {
                await job.value
                return
            }
            if poll == Self.preloadAwaitPolls / 2 { ensureSequentialPreload(startIndex: index) }
            try? await Task.sleep(nanoseconds: Self.preloadAwaitPollMs * 1_000_000)
        }
    }

    private func cancelCompetingPreloads(urgentIndex: Int) {
        stateLock.lock()
        for (key, job) in preloadJobs where key != urgentIndex {
            job.cancel()
            preloadJobs.removeValue(forKey: key)
        }
        stateLock.unlock()
    }

    private func preloadCurrentNow(_ index: Int) {
        guard index == currentIndexSnapshot(), !hasPreloadedAudio(index) else { return }
        stateLock.lock()
        let active = preloadJobs[index] != nil
        stateLock.unlock()
        guard !active else { return }
        cancelCompetingPreloads(urgentIndex: index)
        preloadNext(index: index)
    }

    private func enablePreloadsAfterPlaybackStart(_ sentenceIndex: Int) {
        stateLock.lock(); preloadsEnabled = true; stateLock.unlock()
        schedulePreloadWindow(fromCurrentIndex: sentenceIndex)
    }

    private func schedulePreloadWindow(fromCurrentIndex: Int) {
        guard sherpaEngine.isReady(), isPreloadsEnabled() else { return }
        trimPreloadCache()
        prefetchTextWindow(fromCurrentIndex: fromCurrentIndex)
        ensureSequentialPreload(startIndex: fromCurrentIndex + 1)
    }

    private func schedulePreloadsAfterSentence() { schedulePreloadWindow(fromCurrentIndex: currentIndexSnapshot()) }

    private func ensureSequentialPreload(startIndex: Int) {
        guard sherpaEngine.isReady(), isPreloadsEnabled() else { return }
        stateLock.lock()
        let current = currentIndex
        let endIndex = min(current + Self.maxPreloadAhead, max(sentences.count - 1, 0))
        let firstIndex = max(startIndex, current + 1)
        guard firstIndex <= endIndex, firstIndex < sentences.count else { stateLock.unlock(); return }
        for index in firstIndex...endIndex {
            if preloadedAudio[index] != nil { continue }
            if preloadJobs[index] != nil { stateLock.unlock(); return }
            preloadNextLocked(index)
            stateLock.unlock()
            return
        }
        stateLock.unlock()
    }

    private func trimPreloadCacheInLock() {
        let keepFrom = currentIndex
        let keepTo = currentIndex + Self.maxPreloadAhead
        for key in preloadedAudio.keys where key < keepFrom || key > keepTo { preloadedAudio.removeValue(forKey: key) }
        for key in prefetchedText.keys where key < keepFrom || key > keepTo {
            prefetchedText.removeValue(forKey: key)
            prefetchTextJobs.removeValue(forKey: key)?.cancel()
        }
        for key in preloadJobs.keys where key < keepFrom || key > keepTo {
            preloadJobs.removeValue(forKey: key)?.cancel()
        }
        if nextPreloadIndex < keepFrom || nextPreloadIndex > keepTo { nextPreloadIndex = -1 }
    }

    private func trimPreloadCache() {
        stateLock.lock(); trimPreloadCacheInLock(); stateLock.unlock()
    }

    private func preloadNext(index: Int) {
        guard sherpaEngine.isReady(), isPreloadsEnabled(), index < sentencesCount() else { return }
        stateLock.lock()
        if preloadedAudio[index] != nil { stateLock.unlock(); chainPreloadAfter(completedIndex: index); return }
        if preloadJobs[index] != nil { stateLock.unlock(); return }
        if index > currentIndex + Self.maxPreloadAhead { stateLock.unlock(); return }
        if preloadJobs.contains(where: { $0.key != index }) { stateLock.unlock(); return }
        preloadNextLocked(index)
        stateLock.unlock()
    }

    /// Caller must hold stateLock.
    private func preloadNextLocked(_ index: Int) {
        nextPreloadIndex = index
        let preloadSession = playbackSession
        let current = currentIndex
        let job = Task { [weak self] in
            guard let self else { return }
            await self.runPreload(index: index, preloadSession: preloadSession, currentIndexAtStart: current)
        }
        preloadJobs[index] = job
    }

    private func runPreload(index: Int, preloadSession: Int, currentIndexAtStart: Int) async {
        defer {
            stateLock.lock()
            preloadJobs.removeValue(forKey: index)
            if nextPreloadIndex == index { nextPreloadIndex = -1 }
            stateLock.unlock()
            chainPreloadAfter(completedIndex: index)
        }
        guard sherpaEngine.isReady(), isPreloadsEnabled(), index < sentencesCount() else { return }
        if hasPreloadedAudio(index) { return }

        let sentence = sentenceAt(index)
        let raw = await loadSentenceText(sentence, index: index)
        guard let text = await adaptTextForCurrentModel(raw: raw) else { return }
        let chunks = TtsTextChunker.chunk(text, maxChars: Self.maxSherpaTextChars)
        guard !chunks.isEmpty else { return }

        let effectiveSpeakerId = speakerIdSnapshot()
        let speed = sherpaSpeed
        var pcmChunks: [[Float]] = []
        var sampleRate = 0
        let gain = StreamingGain()
        let start = Self.nowMs()

        await sherpaInitCoordinator.withSherpaThreadAsync {
            let resolved = self.sherpaEngine.resolveSpeakerId(effectiveSpeakerId)
            let engineSampleRate = self.sherpaEngine.sampleRate()
            for chunk in chunks {
                if Task.isCancelled || !self.isPreloadsEnabled() { break }
                var samples: [Float] = []
                let stats = self.sherpaEngine.synthesizeStreaming(
                    text: chunk, speed: speed, speakerId: resolved,
                    shouldContinue: { !Task.isCancelled && self.isPreloadsEnabled() },
                    onChunk: { incoming in
                        if Task.isCancelled || !self.isPreloadsEnabled() { return 0 }
                        var mutable = incoming
                        gain.applyInPlace(&mutable, sampleRate: engineSampleRate)
                        if sampleRate == 0 { sampleRate = engineSampleRate }
                        pcmChunks.append(mutable)
                        samples.append(contentsOf: mutable)
                        return 1
                    }
                )
                if stats == nil || (stats?.totalSamples ?? 0) <= 0 {
                    if let batch = self.sherpaEngine.synthesize(text: chunk, speed: speed, speakerId: resolved), batch.isPlayable {
                        var mutable = batch.samples
                        gain.applyInPlace(&mutable, sampleRate: batch.sampleRate > 0 ? batch.sampleRate : engineSampleRate)
                        pcmChunks.append(mutable)
                        if sampleRate == 0 { sampleRate = batch.sampleRate }
                    } else {
                        break
                    }
                } else if stats?.stoppedEarly == true {
                    break
                } else if sampleRate == 0 {
                    sampleRate = stats?.sampleRate ?? sampleRate
                }
            }
        }
        _ = start

        let synthesisMs = Self.nowMs() - start
        let preloaded = PreloadedSentence(pcmChunks: pcmChunks, sampleRate: sampleRate, synthesisMs: synthesisMs)
        guard preloaded.isPlayable else { return }
        if let reason = preloadDiscardReason(index: index, preloadSession: preloadSession) {
            _ = reason
            return
        }
        stateLock.lock()
        trimPreloadCacheInLock()
        preloadedAudio[index] = preloaded
        stateLock.unlock()
    }

    private func chainPreloadAfter(completedIndex: Int) {
        guard isPreloadsEnabled() else { return }
        let nextIndex = completedIndex + 1
        let current = currentIndexSnapshot()
        guard nextIndex <= current + Self.maxPreloadAhead, nextIndex < sentencesCount() else { return }
        stateLock.lock()
        let shouldChain = preloadedAudio[nextIndex] != nil || preloadJobs[nextIndex] != nil
        stateLock.unlock()
        if shouldChain {
            ensureSequentialPreload(startIndex: nextIndex + 1)
        } else {
            preloadNext(index: nextIndex)
        }
    }

    private func preloadDiscardReason(index: Int, preloadSession: Int) -> String? {
        if !isPreloadsEnabled() { return "preloads_disabled" }
        if preloadSession != currentSession() { return "session_mismatch" }
        if pauseInFlight.get(), !isPlaying.get() { return "pause_finalizing" }
        if index < currentIndexSnapshot() { return "stale_index" }
        return nil
    }

    private func estimatedPlayMs(_ chunks: [[Float]], sampleRate: Int) -> Int64 {
        guard sampleRate > 0 else { return 0 }
        return chunks.reduce(0) { $0 + Int64($1.count) * 1000 / Int64(sampleRate) }
    }

    private func peekSentenceDurationMs(_ index: Int) -> Int64? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let cached = preloadedAudio[index], cached.isPlayable else { return nil }
        return estimatedPlayMs(cached.pcmChunks, sampleRate: cached.sampleRate)
    }

    private func sanitizeCurrentSentencePosition() -> Bool {
        stateLock.lock()
        let index = currentIndex
        let position = positionInSentenceMs
        stateLock.unlock()
        let sanitized = SentencePlaybackPosition.sanitizePositionForSentence(position, durationMs: peekSentenceDurationMs(index))
        guard sanitized != position else { return false }
        stateLock.lock(); positionInSentenceMs = sanitized; stateLock.unlock()
        PlaybackController.shared.update { $0.copy(positionInSentenceMs: sanitized) }
        return true
    }

    private func advanceIfSentenceAlreadyFinished(saveProgress: Bool = true) -> Bool {
        stateLock.lock()
        let index = currentIndex
        let position = positionInSentenceMs
        stateLock.unlock()
        guard position > 0, index < sentencesCount() else { return false }
        _ = sanitizeCurrentSentencePosition()
        guard let durationMs = peekSentenceDurationMs(index) else { return false }
        guard SentencePlaybackPosition.isSentencePositionAtEnd(positionInSentenceMsSnapshot(), durationMs) else { return false }
        stateLock.lock()
        positionInSentenceMs = 0
        lastSentenceEndMs = Self.nowMs()
        currentIndex += 1
        stateLock.unlock()
        invalidateSentenceFrameSnapshot()
        syncPlaybackIndexToController()
        if saveProgress { saveProgressAsync() }
        return true
    }

    private func syncPlaybackIndexToController() {
        stateLock.lock()
        let index = currentIndex
        let pos = positionInSentenceMs
        if index < sentences.count {
            let preview = sentences[index].textPreview
            stateLock.unlock()
            PlaybackController.shared.update {
                $0.copy(currentSentenceIndex: index, currentSentenceText: preview, positionInSentenceMs: pos)
            }
        } else {
            stateLock.unlock()
            PlaybackController.shared.update { $0.copy(positionInSentenceMs: pos) }
        }
    }

    private func speakerIdSnapshot() -> Int { stateLock.lock(); defer { stateLock.unlock() }; return speakerId }

    // MARK: - Playing

    private func playCachedSherpa(cached: PreloadedSentence, startMs: Int64, notifyStartup: Bool, sentenceIndex: Int, subtitleText: String) async -> SherpaPlayResult {
        guard cached.isPlayable else {
            return .failed(userMessage: PlaybackMessages.errorSynthesisEmptyAudio, logDetail: "cached not playable index=\(sentenceIndex)")
        }
        let session = currentSession()
        var skipMs = startMs
        var notifyOnNextPlay = notifyStartup
        var pendingSubtitle: SubtitleUpdate? = SubtitleUpdate(index: sentenceIndex, text: subtitleText, totalSentences: sentencesCount())
        let sampleRate = cached.sampleRate
        var playbackStarted = false

        return await sherpaInitCoordinator.withSherpaThreadAsync {
            if !self.preparePcmPlayer(sampleRate: sampleRate) {
                return .failed(userMessage: PlaybackMessages.errorAudioInit, logDetail: "pcm prepare failed rate=\(sampleRate)")
            }
            let framesBeforeSentence = self.pcmPlayer.framesWritten
            self.markSentencePlaybackStart(sampleRate: sampleRate)

            for chunk in cached.pcmChunks {
                if !self.isPlaying.get() || session != self.currentSession() { return .interrupted }
                let chunkDurationMs = Int64(chunk.count) * 1000 / Int64(sampleRate)
                if skipMs >= chunkDurationMs { skipMs -= chunkDurationMs; continue }
                let skipSamples = skipMs > 0 ? Int(skipMs * Int64(sampleRate) / 1000) : 0
                skipMs = 0

                if !playbackStarted {
                    if !self.pcmPlayer.isInitialized, !self.preparePcmPlayer(sampleRate: sampleRate) {
                        return .failed(userMessage: PlaybackMessages.errorAudioInit, logDetail: "cached prepare failed")
                    }
                    if notifyOnNextPlay { self.markOutputtingAudioIfStartup() }
                    self.pcmPlayer.ensurePlaying()
                    playbackStarted = true
                    self.notifyStreamPlaybackStarted(notifyStartup: notifyOnNextPlay, subtitle: pendingSubtitle, sentenceIndex: sentenceIndex)
                    notifyOnNextPlay = false
                    pendingSubtitle = nil
                }

                let shouldContinue = { self.isPlaying.get() && session == self.currentSession() }
                let written = skipSamples > 0
                    ? self.pcmPlayer.writeSamplesFromOffset(chunk, startSample: skipSamples, shouldContinue: shouldContinue)
                    : self.pcmPlayer.writeSamples(chunk, shouldContinue: shouldContinue)
                if written < 0 {
                    if !self.isPlaying.get() { return .interrupted }
                    return .failed(userMessage: PlaybackMessages.errorAudioWrite, logDetail: "cached write failed index=\(sentenceIndex)")
                }
                if !self.isPlaying.get() || session != self.currentSession() { return .interrupted }

                if playbackStarted {
                    await self.waitForSentencePlayback(session: session, framesBeforeWrite: framesBeforeSentence, framesEnd: self.pcmPlayer.framesWritten, sampleRate: sampleRate, progressBaseMs: startMs, sentenceIndex: sentenceIndex)
                    if !self.isPlaying.get() || session != self.currentSession() { return .interrupted }
                }
            }

            if playbackStarted {
                let head = self.pcmPlayer.playbackHeadFrames()
                let writtenFrames = self.pcmPlayer.framesWritten - framesBeforeSentence
                let playedFrames = max(head - framesBeforeSentence, 0)
                if writtenFrames > 0, playedFrames == 0 {
                    return .failed(userMessage: PlaybackMessages.errorAudioWrite, logDetail: "cached head never advanced")
                }
            }
            return .completed
        }
    }

    private func streamSynthAndPlay(text: String, startMs: Int64, notifyStartup: Bool, sentenceIndex: Int) async -> SherpaPlayResult {
        let textChunks = TtsTextChunker.chunk(text, maxChars: Self.maxSherpaTextChars)
        guard !textChunks.isEmpty else {
            return synthesisFailure(PlaybackMessages.errorEmptyText, "empty text chunks")
        }

        let initResult = await ensureSherpaEngineForPlayback()
        guard initResult.isSuccess else {
            if case .notDownloaded = initResult {
                return .failed(userMessage: PlaybackMessages.noModelDownloaded, logDetail: "no default model")
            }
            return .failed(userMessage: initResult.userMessage, logDetail: "engine init failed: \(initResult)")
        }
        guard sherpaEngine.isReady() else {
            return .failed(userMessage: PlaybackMessages.engineNotReady, logDetail: "engine not ready")
        }

        let session = currentSession()
        let gain = StreamingGain()
        let writeState = StreamChunkWriteState(
            skipMs: startMs, notifyStartup: notifyStartup,
            subtitle: SubtitleUpdate(index: sentenceIndex, text: text, totalSentences: sentencesCount()),
            sentenceIndex: sentenceIndex, session: session
        )
        let defaultModel = try? await ttsRepository.getDefaultModel()
        let effectiveSpeakerId = await sherpaInitCoordinator.withSherpaThreadAsync {
            self.sherpaEngine.resolveSpeakerId((defaultModel ?? nil)?.speakerId ?? self.speakerIdSnapshot())
        }
        let sampleRate = await sherpaInitCoordinator.withSherpaThreadAsync { self.sherpaEngine.sampleRate() }
        guard sampleRate > 0 else {
            return synthesisFailure("引擎采样率无效", "sampleRate=0")
        }

        var lastStats: StreamingSynthStats?
        var prepareFailed = false
        var framesBeforeSentence: Int64?

        await sherpaInitCoordinator.withSherpaThreadAsync {
            if !self.preparePcmPlayer(sampleRate: sampleRate) { prepareFailed = true; return }
            framesBeforeSentence = self.pcmPlayer.framesWritten
            self.markSentencePlaybackStart(sampleRate: sampleRate)
            for textChunk in textChunks {
                if !(self.isPlaying.get() && session == self.currentSession()) { return }
                let stats = self.synthesizeChunkForPlayback(
                    textChunk: textChunk, effectiveSpeakerId: effectiveSpeakerId, sampleRate: sampleRate,
                    gain: gain, writeState: writeState, sentenceIndex: sentenceIndex
                )
                if stats == nil { return }
                lastStats = stats
            }
        }

        if prepareFailed {
            return .failed(userMessage: PlaybackMessages.errorAudioInit, logDetail: "pcm prepare failed rate=\(sampleRate)")
        }
        guard let framesBase = framesBeforeSentence else {
            return .failed(userMessage: PlaybackMessages.errorAudioInit, logDetail: "pcm prepare failed rate=\(sampleRate)")
        }

        let needsFallback = !writeState.playbackStarted && (lastStats == nil || (lastStats?.totalSamples ?? 0) == 0)
        if needsFallback, isPlaying.get(), session == currentSession() {
            lastStats = await sherpaInitCoordinator.withSherpaThreadAsync {
                self.batchPlayTextChunks(textChunks: textChunks, effectiveSpeakerId: effectiveSpeakerId, sampleRate: sampleRate, gain: gain, writeState: writeState)
            }
        }

        if !isPlaying.get() || session != currentSession() { return .interrupted }
        if !writeState.playbackStarted {
            let estimatedDurationMs = estimateTextChunksDurationMs(totalSamples: lastStats?.totalSamples ?? 0, sampleRate: sampleRate)
            if startMs > 0, estimatedDurationMs > 0, SentencePlaybackPosition.isSentencePositionAtEnd(startMs, estimatedDurationMs) {
                return .completed
            }
            if lastStats == nil {
                return await diagnoseStreamSynthFailure(textChunks: textChunks, effectiveSpeakerId: effectiveSpeakerId, sentenceIndex: sentenceIndex, session: session)
            }
            if (lastStats?.totalSamples ?? 0) > 0 {
                return .failed(userMessage: PlaybackMessages.errorAudioInit, logDetail: "had samples but playback not started")
            }
            return synthesisFailure(PlaybackMessages.errorSynthesisEmptyAudio, "no playable audio")
        }

        await waitForSentencePlayback(session: session, framesBeforeWrite: framesBase, framesEnd: pcmPlayer.framesWritten, sampleRate: sampleRate, progressBaseMs: startMs, sentenceIndex: sentenceIndex)
        if writeState.playbackStarted {
            let head = pcmPlayer.playbackHeadFrames()
            let writtenFrames = pcmPlayer.framesWritten - framesBase
            let playedFrames = max(head - framesBase, 0)
            if writtenFrames > 0, playedFrames == 0 {
                return .failed(userMessage: PlaybackMessages.errorAudioWrite, logDetail: "stream head never advanced")
            }
        }
        return (!isPlaying.get() || session != currentSession()) ? .interrupted : .completed
    }

    private func synthesizeChunkForPlayback(textChunk: String, effectiveSpeakerId: Int, sampleRate: Int, gain: StreamingGain, writeState: StreamChunkWriteState, sentenceIndex: Int) -> StreamingSynthStats? {
        guard isPlaying.get() && writeState.session == currentSession() else { return nil }
        var samplesWritten = 0
        let streamStats = sherpaEngine.synthesizeStreaming(
            text: textChunk, speed: sherpaSpeed, speakerId: effectiveSpeakerId,
            shouldContinue: { self.isPlaying.get() && writeState.session == self.currentSession() },
            onChunk: { samples in
                guard self.isPlaying.get() && writeState.session == self.currentSession() else { return 0 }
                let framesBefore = self.pcmPlayer.framesWritten
                let result = self.writeStreamChunk(samples: samples, gain: gain, sampleRate: sampleRate, state: writeState)
                if result < 0 { return 0 }
                let framesAfter = self.pcmPlayer.framesWritten
                if framesAfter > framesBefore { samplesWritten += Int(framesAfter - framesBefore) }
                return result == 0 ? 0 : 1
            }
        )
        if streamStats == nil || (streamStats?.stoppedEarly == true && samplesWritten <= 0) {
            guard let batch = sherpaEngine.synthesize(text: textChunk, speed: sherpaSpeed, speakerId: effectiveSpeakerId) else { return nil }
            return playBatchChunk(batch: batch, gain: gain, sampleRate: sampleRate, state: writeState)
        }
        return streamStats
    }

    private func batchPlayTextChunks(textChunks: [String], effectiveSpeakerId: Int, sampleRate: Int, gain: StreamingGain, writeState: StreamChunkWriteState) -> StreamingSynthStats? {
        guard preparePcmPlayer(sampleRate: sampleRate) else { return nil }
        var totalSamples = 0
        var invocations = 0
        for textChunk in textChunks {
            if !(isPlaying.get() && writeState.session == currentSession()) { break }
            guard let batch = sherpaEngine.synthesize(text: textChunk, speed: sherpaSpeed, speakerId: effectiveSpeakerId),
                  let stats = playBatchChunk(batch: batch, gain: gain, sampleRate: sampleRate, state: writeState) else { return nil }
            totalSamples += stats.totalSamples
            invocations += stats.callbackInvocations
        }
        if totalSamples <= 0, !writeState.playbackStarted { return nil }
        return StreamingSynthStats(sampleRate: sampleRate, totalSamples: totalSamples, callbackInvocations: invocations, stoppedEarly: false)
    }

    private func writeStreamChunk(samples: [Float], gain: StreamingGain, sampleRate: Int, state: StreamChunkWriteState) -> Int {
        guard sampleRate > 0, !samples.isEmpty else { return 0 }
        var mutable = samples
        gain.applyInPlace(&mutable, sampleRate: sampleRate)

        let chunkDurationMs = Int64(mutable.count) * 1000 / Int64(sampleRate)
        if state.skipMs >= chunkDurationMs { state.skipMs -= chunkDurationMs; return 1 }
        let skipSamples = state.skipMs > 0 ? Int(state.skipMs * Int64(sampleRate) / 1000) : 0
        state.skipMs = 0

        if !pcmPlayer.isInitialized, !preparePcmPlayer(sampleRate: sampleRate) {
            return -1
        }
        if !state.playbackStarted {
            if !isPlaying.get() { return 0 }
            if state.notifyStartup { markOutputtingAudioIfStartup() }
            pcmPlayer.ensurePlaying()
            state.playbackStarted = true
            notifyStreamPlaybackStarted(notifyStartup: state.notifyStartup, subtitle: state.subtitle, sentenceIndex: state.sentenceIndex)
            state.notifyStartup = false
            state.subtitle = nil
        }
        let shouldContinue = { self.isPlaying.get() && state.session == self.currentSession() }
        let written = skipSamples > 0
            ? pcmPlayer.writeSamplesFromOffset(mutable, startSample: skipSamples, shouldContinue: shouldContinue)
            : pcmPlayer.writeSamples(mutable, shouldContinue: shouldContinue)
        if written < 0, !isPlaying.get() { return 0 }
        if written < 0 { return -1 }
        return written == 0 ? 0 : 1
    }

    private func playBatchChunk(batch: SynthesizedAudio?, gain: StreamingGain, sampleRate: Int, state: StreamChunkWriteState) -> StreamingSynthStats? {
        guard let batch, batch.isPlayable else { return nil }
        let rate = batch.sampleRate > 0 ? batch.sampleRate : sampleRate
        let result = writeStreamChunk(samples: batch.samples, gain: gain, sampleRate: rate, state: state)
        if result < 0 { return nil }
        if result == 0, !state.playbackStarted { return nil }
        return StreamingSynthStats(sampleRate: rate, totalSamples: batch.samples.count, callbackInvocations: 1, stoppedEarly: result == 0)
    }

    private func notifyStreamPlaybackStarted(notifyStartup: Bool, subtitle: SubtitleUpdate?, sentenceIndex: Int) {
        guard isPlaying.get() else { return }
        PlaybackController.shared.update { state in
            var next = state
            if let subtitle {
                next = next.copy(currentSentenceIndex: subtitle.index, totalSentences: subtitle.totalSentences, currentSentenceText: subtitle.text)
            }
            if notifyStartup || next.playbackState != .playing {
                next = next.copy(playbackState: .playing, loadingStage: .none)
            }
            return next
        }
        if notifyStartup { finishStartupToast() }
        enablePreloadsAfterPlaybackStart(sentenceIndex)
    }

    private func waitForSentencePlayback(session: Int, framesBeforeWrite: Int64, framesEnd: Int64, sampleRate: Int, progressBaseMs: Int64, sentenceIndex: Int) async {
        let framesToPlay = max(framesEnd - framesBeforeWrite, 0)
        let timeoutMs = PlaybackHeadWaitPolicy.expectedTimeoutMs(framesToPlay: framesToPlay, sampleRate: sampleRate)
        let startMs = Self.nowMs()
        while !Task.isCancelled {
            if !isPlaying.get() || session != currentSession() { return }
            let headFrames = pcmPlayer.playbackHeadFrames()
            let playedFrames = max(headFrames - framesBeforeWrite, 0)
            let positionMs = progressBaseMs + playedFrames * 1000 / Int64(sampleRate)
            stateLock.lock(); positionInSentenceMs = positionMs; stateLock.unlock()
            if isPlaying.get() { PlaybackController.shared.update { $0.copy(positionInSentenceMs: positionMs) } }
            if headFrames >= framesEnd { return }
            if Self.nowMs() - startMs >= timeoutMs { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func diagnoseStreamSynthFailure(textChunks: [String], effectiveSpeakerId: Int, sentenceIndex: Int, session: Int) async -> SherpaPlayResult {
        guard let probeText = textChunks.first else {
            return synthesisFailure(PlaybackMessages.errorSynthesisEmptyAudio, "no probe text")
        }
        let probe = await sherpaInitCoordinator.withSherpaThreadAsync {
            self.sherpaEngine.synthesize(text: probeText, speed: self.sherpaSpeed, speakerId: effectiveSpeakerId)
        }
        if probe == nil || !(probe?.isPlayable ?? false) {
            return synthesisFailure(PlaybackMessages.errorSynthesisEmptyAudio, "probe failed")
        }
        return .failed(userMessage: PlaybackMessages.errorAudioInit, logDetail: "probe ok but playback write failed")
    }

    private func synthesisFailure(_ reason: String, _ logDetail: String) -> SherpaPlayResult {
        .failed(userMessage: PlaybackMessages.synthesisFailed(reason), logDetail: logDetail)
    }

    private func estimateTextChunksDurationMs(totalSamples: Int, sampleRate: Int) -> Int64 {
        guard totalSamples > 0, sampleRate > 0 else { return 0 }
        return Int64(totalSamples) * 1000 / Int64(sampleRate)
    }

    // MARK: - Engine init

    private func ensureSherpaEngineForPlayback() async -> SherpaInitResult {
        guard let model = (try? await ttsRepository.getDefaultModel()) ?? nil else {
            return .notDownloaded
        }
        let result = await ensureSherpaInitializedWithRetry(model: model)
        if result.isSuccess {
            await refreshSpeakerId(model: model)
            activeTtsKey = sherpaInitCoordinator.initKeyFor(model)
        }
        return result
    }

    private func ensureSherpaInitializedWithRetry(model: TtsModelEntity?) async -> SherpaInitResult {
        guard let model,
              model.downloadState == TtsDownloadState.downloaded.rawValue,
              model.localPath != nil else {
            return .notDownloaded
        }
        if !sherpaInitCoordinator.isReadyFor(model) { cancelPreloads() }
        var result = await sherpaInitCoordinator.ensureInitialized(model)
        if shouldRetrySherpaInit(result) {
            cancelPreloads()
            try? await Task.sleep(nanoseconds: UInt64(Self.initRetryDelayMs) * 1_000_000)
            result = await sherpaInitCoordinator.ensureInitialized(model)
        }
        return result
    }

    private func shouldRetrySherpaInit(_ result: SherpaInitResult) -> Bool {
        switch result {
        case .modelLoadFailed, .lowMemory, .outOfMemory: return true
        default: return false
        }
    }

    private func releaseSherpaEngine() async {
        cancelPreloads()
        sherpaInitCoordinator.invalidate()
        await sherpaInitCoordinator.withSherpaThreadAsync { self.sherpaEngine.release() }
    }

    private func cancelPreloads() {
        stateLock.lock()
        for (_, job) in preloadJobs { job.cancel() }
        preloadJobs.removeAll()
        preloadedAudio.removeAll()
        for (_, job) in prefetchTextJobs { job.cancel() }
        prefetchTextJobs.removeAll()
        prefetchedText.removeAll()
        nextPreloadIndex = -1
        stateLock.unlock()
    }

    private func safePauseAudioTrack() { pcmPlayer.pauseImmediately() }

    private func releaseAudioTrack() {
        stateLock.lock(); audioTrackNeedsReset = true; stateLock.unlock()
        pcmPlayer.release()
    }

    private func prepareForTtsPreview() {
        isPlaying.set(false)
        stateLock.lock(); playbackJob?.cancel(); playbackJob = nil; startupToastPending = false; stateLock.unlock()
        cancelPreloads()
        pcmPlayer.signalStopRequested()
        pcmPlayer.pauseImmediately()
        Task {
            _ = await sherpaInitCoordinator.withSherpaThreadAsync { }
        }
    }

    // MARK: - Pause / resume / seek

    private func pausePlayback(persistSession: Bool = true) {
        guard pauseInFlight.compareAndSet(false, true) else { return }
        isPlaying.set(false)
        wakeLock.release()
        if persistSession { persistPlaybackSession(shouldResumeOnRestart: false) }
        pcmPlayer.signalStopRequested()
        pcmPlayer.pauseImmediately()
        stateLock.lock()
        startupToastPending = false
        playbackSession += 1
        startPlaybackJob?.cancel(); startPlaybackJob = nil
        playFromCurrentJob?.cancel(); playFromCurrentJob = nil
        drainedPlaybackJob = playbackJob
        playbackJob?.cancel(); playbackJob = nil
        stateLock.unlock()
        PlaybackController.shared.update { $0.copy(playbackState: .paused, loadingStage: .none) }
        submitAudioStop(snapshotPosition: true)

        stateLock.lock()
        pauseFinalizeJob?.cancel()
        let pauseSessionAtStart = playbackSession
        pauseFinalizeJob = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.seekAudioStopTimeoutMs) * 1_000_000)
            if self.shouldSkipPauseFinalize(pauseSessionAtStart: pauseSessionAtStart) { self.finishPauseFinalize(); return }
            _ = self.sanitizeCurrentSentencePosition()
            if self.shouldSkipPauseFinalize(pauseSessionAtStart: pauseSessionAtStart) { self.finishPauseFinalize(); return }
            _ = self.advanceIfSentenceAlreadyFinished(saveProgress: false)
            if self.shouldSkipPauseFinalize(pauseSessionAtStart: pauseSessionAtStart) { self.finishPauseFinalize(); return }
            await self.saveProgress()
            if self.shouldSkipPauseFinalize(pauseSessionAtStart: pauseSessionAtStart) { self.finishPauseFinalize(); return }
            self.cancelPreloads()
            self.invalidateSentenceFrameSnapshot()
            self.finishPauseFinalize()
        }
        stateLock.unlock()
    }

    private func finishPauseFinalize() {
        pauseInFlight.set(false)
        stateLock.lock(); pauseFinalizeJob = nil; stateLock.unlock()
    }

    private func shouldSkipPauseFinalize(pauseSessionAtStart: Int) -> Bool {
        PlaybackTransitionGuards.shouldSkipPauseFinalize(
            isPlaying: isPlaying.get(),
            pauseSessionAtStart: pauseSessionAtStart,
            currentSession: currentSession()
        )
    }

    private func resumePlayback() {
        guard resumeInFlight.compareAndSet(false, true) else { return }
        if currentSentencesEmpty() {
            let id = currentBookId()
            if !id.isEmpty { launchStartPlayback(id) }
            resumeInFlight.set(false)
            return
        }
        stateLock.lock()
        let alreadyActive = isPlaying.get() && (playbackJob != nil || playFromCurrentJob != nil)
        stateLock.unlock()
        if alreadyActive { resumeInFlight.set(false); return }

        let signal = ResumeSignal()
        stateLock.lock(); resumeStartSignal = { signal.fire() }; stateLock.unlock()

        Task { [weak self] in
            guard let self else { return }
            await self.awaitPauseTransitionComplete()
            if !self.sherpaEngine.isReady() {
                let defaultModel = (try? await self.ttsRepository.getDefaultModel()) ?? nil
                let initResult = await self.ensureSherpaInitializedWithRetry(model: defaultModel)
                if initResult.isSuccess {
                    await self.refreshSpeakerId(model: defaultModel)
                    self.activeTtsKey = self.sherpaInitCoordinator.initKeyFor(defaultModel)
                    self.beginResumePlayback()
                } else {
                    self.failPlayback(initResult.userMessage)
                }
            } else {
                self.beginResumePlayback()
            }
            let started = await signal.wait(timeoutMs: Self.resumeLoopStartTimeoutMs)
            if !started, self.isPlaying.get(), self.currentIndexSnapshot() < self.sentencesCount() {
                self.schedulePlaybackRecoveryIfNeeded()
            }
            self.stateLock.lock()
            self.resumeStartSignal = nil
            self.stateLock.unlock()
            self.resumeInFlight.set(false)
        }
    }

    private func awaitPauseTransitionComplete() async {
        stateLock.lock(); let job = pauseFinalizeJob; stateLock.unlock()
        guard let job else { return }
        job.cancel()
    }

    private func signalResumeLoopStarted() {
        stateLock.lock(); let signal = resumeStartSignal; stateLock.unlock()
        signal?()
    }

    private func abortPlayFromCurrent(reason: String) {
        if isPlaying.get(), currentIndexSnapshot() < sentencesCount() {
            schedulePlaybackRecoveryIfNeeded()
        } else if PlaybackController.shared.snapshot.playbackState == .playing, !isPlaying.get() {
            PlaybackController.shared.update { $0.copy(playbackState: .paused, loadingStage: .none) }
        }
        signalResumeLoopStarted()
    }

    private func startPlaybackPipeline(forceRestart: Bool) {
        _ = sanitizeCurrentSentencePosition()
        _ = advanceIfSentenceAlreadyFinished()
        if currentIndexSnapshot() >= sentencesCount() {
            pausePlayback()
            PlaybackController.shared.update { $0.copy(playbackState: .stopped) }
            return
        }
        isPlaying.set(true)
        PlaybackController.shared.update { $0.copy(playbackState: .playing, loadingStage: .none) }
        stateLock.lock(); preloadsEnabled = true; stateLock.unlock()
        playFromCurrent(forceRestart: forceRestart)
    }

    private func beginResumePlayback() { startPlaybackPipeline(forceRestart: true) }

    private func applySpeedChange() {
        if isPlaying.get() {
            showTtsToast(PlaybackMessages.applyingSpeed)
            restartPlaybackFromCurrent(clearPreloads: true)
        } else {
            cancelPreloads()
            releaseAudioTrack()
        }
    }

    private func syncTtsEngine() async {
        let defaultModel = (try? await ttsRepository.getDefaultModel()) ?? nil
        let initResult = await ensureSherpaEngineForPlayback()
        guard initResult.isSuccess else {
            if isPlaying.get() { failPlayback(initResult.userMessage) }
            return
        }
        await refreshSpeakerId(model: defaultModel)
        activeTtsKey = sherpaInitCoordinator.initKeyFor(defaultModel)
        stateLock.lock(); preloadsEnabled = false; stateLock.unlock()
        cancelPreloads()
        if isPlaying.get() { restartPlaybackFromCurrent(clearPreloads: true) }
    }

    private func reloadTtsEngine() async {
        showTtsToast(PlaybackMessages.reloadingEngine)
        let wasPlaying = isPlaying.get()
        if wasPlaying {
            isPlaying.set(false)
            stateLock.lock()
            drainedPlaybackJob = playbackJob
            playbackJob?.cancel(); playbackJob = nil
            stateLock.unlock()
            safePauseAudioTrack()
        }
        let defaultModel = (try? await ttsRepository.getDefaultModel()) ?? nil
        let initResult = await awaitReinitializeTts(defaultModel: defaultModel)
        if initResult.isSuccess {
            stateLock.lock(); preloadsEnabled = true; stateLock.unlock()
            if wasPlaying { startPlaybackPipeline(forceRestart: true) }
        } else {
            failPlayback(initResult.userMessage)
        }
    }

    private func refreshSpeakerId(model: TtsModelEntity?) async {
        var resolved = model?.speakerId ?? 0
        if sherpaEngine.isReady() {
            resolved = await sherpaInitCoordinator.withSherpaThreadAsync { self.sherpaEngine.resolveSpeakerId(resolved) }
        }
        stateLock.lock(); speakerId = resolved; stateLock.unlock()
    }

    private func awaitReinitializeTts(defaultModel: TtsModelEntity?) async -> SherpaInitResult {
        guard let defaultModel, let initKey = sherpaInitCoordinator.initKeyFor(defaultModel) else {
            return .notDownloaded
        }
        let cacheHit = sherpaInitCoordinator.isReadyFor(defaultModel)
        if !cacheHit {
            setLoadingStage(.initEngine)
            showTtsToast(PlaybackMessages.startupInitEngine)
            if defaultModel.downloadState == TtsDownloadState.downloaded.rawValue, defaultModel.localPath != nil {
                setLoadingStage(.initSherpa)
                showTtsToast(PlaybackMessages.startupInitSherpa(defaultModel.name))
            }
        }
        cancelPreloads()
        let result = await ensureSherpaInitializedWithRetry(model: defaultModel)
        if result.isSuccess {
            await refreshSpeakerId(model: defaultModel)
            activeTtsKey = initKey
            stateLock.lock(); preloadsEnabled = false; stateLock.unlock()
        } else {
            if activeTtsKey != nil {
                await releaseSherpaEngine()
                releaseAudioTrack()
                activeTtsKey = nil
            }
        }
        return result
    }

    private func stopPlayback() {
        invalidateToastSession()
        stateLock.lock(); startPlaybackJob?.cancel(); startPlaybackJob = nil; stateLock.unlock()
        pausePlayback(persistSession: false)
        playbackSessionStore.clear()
        PlaybackController.shared.reset()
        stateLock.lock(); bookId = ""; sentences = []; stateLock.unlock()
    }

    private func abortStartup() {
        stateLock.lock(); startupToastPending = false; stateLock.unlock()
        PlaybackController.shared.update { $0.copy(loadingStage: .none) }
    }

    private func skipSentence(_ offset: Int) {
        stateLock.lock()
        guard !sentences.isEmpty, offset != 0 else { stateLock.unlock(); return }
        let newIndex = min(max(currentIndex + offset, 0), sentences.count - 1)
        let changed = newIndex != currentIndex
        let wasPlaying = isPlaying.get()
        stateLock.unlock()
        guard changed else { return }
        seekToSentenceImmediate(index: newIndex, resume: wasPlaying)
    }

    private func seekToSentenceImmediate(index: Int, resume: Bool) {
        guard seekInFlight.compareAndSet(false, true) else { return }
        stateLock.lock()
        seekGeneration += 1
        let generation = seekGeneration
        playFromCurrentJob?.cancel(); playFromCurrentJob = nil
        currentIndex = min(max(index, 0), max(sentences.count - 1, 0))
        positionInSentenceMs = 0
        let current = currentIndex
        let preview = sentences.indices.contains(current) ? sentences[current].textPreview : ""
        stateLock.unlock()
        invalidateSentenceFrameSnapshot()
        PlaybackController.shared.update { $0.copy(currentSentenceIndex: current, currentSentenceText: preview, positionInSentenceMs: 0) }
        cancelPreloads()
        let previous = interruptPlayback()

        Task { [weak self] in
            guard let self else { return }
            defer { self.seekInFlight.set(false) }
            self.pcmPlayer.pauseImmediately()
            try? await Task.sleep(nanoseconds: UInt64(Self.seekAudioStopTimeoutMs) * 1_000_000)
            if generation != self.currentSeekGeneration() { return }
            self.stateLock.lock(); self.lastSentenceEndMs = 0; self.stateLock.unlock()
            await self.awaitPlaybackDrain(previous)
            if generation != self.currentSeekGeneration() { return }
            if resume {
                if self.currentSentencesEmpty() { return }
                if !self.sherpaEngine.isReady() {
                    self.failPlayback(PlaybackMessages.engineNotReady)
                    return
                }
                self.showTtsToast(PlaybackMessages.seekPreparing)
                self.stateLock.lock(); self.preloadsEnabled = true; self.stateLock.unlock()
                self.startPlaybackPipeline(forceRestart: true)
            }
        }
    }

    private func currentSeekGeneration() -> Int { stateLock.lock(); defer { stateLock.unlock() }; return seekGeneration }

    // MARK: - Sleep timer

    private func clearSleepTimer(persist: Bool = true) {
        stateLock.lock()
        sleepTimerJob?.cancel(); sleepTimerJob = nil
        sleepUntilEndOfBook = false
        stateLock.unlock()
        PlaybackController.shared.update { $0.copy(sleepTimerRemainingMs: 0, sleepUntilEndOfBook: false) }
        if persist { AppSettings.clearSleepTimer() }
    }

    private func scheduleSleepTimer(minutes: Int, untilEnd: Bool) {
        stateLock.lock()
        sleepTimerJob?.cancel(); sleepTimerJob = nil
        stateLock.unlock()
        if !untilEnd, minutes <= 0 { clearSleepTimer(persist: false); return }
        stateLock.lock(); sleepUntilEndOfBook = untilEnd; stateLock.unlock()
        if untilEnd {
            PlaybackController.shared.update { $0.copy(sleepTimerRemainingMs: 0, sleepUntilEndOfBook: true) }
            return
        }
        let totalMs = Int64(minutes) * 60_000
        stateLock.lock()
        sleepTimerJob = Task { [weak self] in
            guard let self else { return }
            var remaining = totalMs
            while remaining > 0, !Task.isCancelled {
                PlaybackController.shared.update { $0.copy(sleepTimerRemainingMs: remaining, sleepUntilEndOfBook: false) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining -= 1000
            }
            if Task.isCancelled { return }
            PlaybackController.shared.update { $0.copy(sleepTimerRemainingMs: 0) }
            self.pausePlayback()
            self.clearSleepTimer(persist: true)
        }
        stateLock.unlock()
    }

    // MARK: - Progress

    private func saveProgressAsync() {
        if isPlaying.get() { persistPlaybackSession(shouldResumeOnRestart: true) }
        Task { await saveProgress() }
    }

    private func saveProgress() async {
        stateLock.lock()
        let id = bookId
        let index = currentIndex
        let pos = positionInSentenceMs
        stateLock.unlock()
        guard !id.isEmpty else { return }
        await bookRepository.saveProgress(id, sentenceIndex: index, positionMs: pos)
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

extension SherpaInitResult {
    var userMessage: String {
        switch self {
        case .notDownloaded: return PlaybackMessages.noModelDownloaded
        case .lowMemory: return PlaybackMessages.initLowMemory(SherpaInitCoordinator.minFreeMB)
        case .outOfMemory: return PlaybackMessages.initOom
        case .modelLoadFailed: return PlaybackMessages.initFailed
        case .error(let detail): return PlaybackMessages.initFailedDetail(detail)
        case .success: return ""
        }
    }
}

private final class ResumeSignal {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func fire() {
        lock.lock()
        if fired { lock.unlock(); return }
        fired = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: true)
    }

    func wait(timeoutMs: Int64) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    self.lock.lock()
                    if self.fired { self.lock.unlock(); cont.resume(returning: true); return }
                    self.continuation = cont
                    self.lock.unlock()
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
