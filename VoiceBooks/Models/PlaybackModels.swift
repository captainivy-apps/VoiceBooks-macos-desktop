import Foundation

enum PlaybackState: String {
    case idle = "IDLE"
    case loading = "LOADING"
    case playing = "PLAYING"
    case paused = "PAUSED"
    case stopped = "STOPPED"
    case error = "ERROR"
}

enum TtsLoadingStage: String {
    case none = "NONE"
    case loadingBook = "LOADING_BOOK"
    case initEngine = "INIT_ENGINE"
    case initSherpa = "INIT_SHERPA"
    case preloading = "PRELOADING"
    case readingText = "READING_TEXT"
    case synthesizing = "SYNTHESIZING"
    case preparingFirst = "PREPARING_FIRST"
    case outputtingAudio = "OUTPUTTING_AUDIO"
}

extension PlaybackUiState {
    /// Kotlin-style partial copy. `nil` means "leave unchanged".
    func copy(
        bookId: String? = nil,
        bookTitle: String? = nil,
        bookAuthor: String? = nil,
        coverPath: String? = nil,
        currentSentenceIndex: Int? = nil,
        totalSentences: Int? = nil,
        currentSentenceText: String? = nil,
        playbackState: PlaybackState? = nil,
        loadingStage: TtsLoadingStage? = nil,
        lastError: String? = nil,
        speed: Float? = nil,
        positionInSentenceMs: Int64? = nil,
        sleepTimerRemainingMs: Int64? = nil,
        sleepUntilEndOfBook: Bool? = nil
    ) -> PlaybackUiState {
        var next = self
        if let bookId { next.bookId = bookId }
        if let bookTitle { next.bookTitle = bookTitle }
        if let bookAuthor { next.bookAuthor = bookAuthor }
        if let coverPath { next.coverPath = coverPath }
        if let currentSentenceIndex { next.currentSentenceIndex = currentSentenceIndex }
        if let totalSentences { next.totalSentences = totalSentences }
        if let currentSentenceText { next.currentSentenceText = currentSentenceText }
        if let playbackState { next.playbackState = playbackState }
        if let loadingStage { next.loadingStage = loadingStage }
        if let lastError { next.lastError = lastError }
        if let speed { next.speed = speed }
        if let positionInSentenceMs { next.positionInSentenceMs = positionInSentenceMs }
        if let sleepTimerRemainingMs { next.sleepTimerRemainingMs = sleepTimerRemainingMs }
        if let sleepUntilEndOfBook { next.sleepUntilEndOfBook = sleepUntilEndOfBook }
        return next
    }
}

struct PlaybackUiState: Equatable {
    var bookId: String = ""
    var bookTitle: String = ""
    var bookAuthor: String = ""
    var coverPath: String? = nil
    var currentSentenceIndex: Int = 0
    var totalSentences: Int = 0
    var currentSentenceText: String = ""
    var playbackState: PlaybackState = .idle
    var loadingStage: TtsLoadingStage = .none
    var lastError: String? = nil
    var speed: Float = 1.0
    var positionInSentenceMs: Int64 = 0
    var sleepTimerRemainingMs: Int64 = 0
    var sleepUntilEndOfBook: Bool = false
}

/// User-facing zh-CN strings for playback, ported from PlaybackMessages.kt / strings.xml.
enum PlaybackMessages {
    static let recovering = "正在恢复播放…"
    static let loadingBook = "正在加载书籍…"
    static let playbackFailedGeneric = "播放出现问题，请重试"
    static let startupPlaying = "开始播放"
    static let startupReadingText = "正在读取当前段落…"
    static let startupSynthesizing = "正在合成语音…"
    static let startupInitEngine = "正在初始化 TTS 引擎…"
    static let applyingSpeed = "正在应用新语速…"
    static let reloadingEngine = "正在重新加载 TTS 引擎…"
    static let seekPreparing = "正在跳转到所选段落…"
    static let errorSynthesisEmptyAudio = "合成结果为空"
    static let errorAudioInit = "AudioTrack 初始化失败"
    static let errorAudioWrite = "AudioTrack 写入失败"
    static let errorEmptyText = "当前段落没有可朗读的文本"
    static let noModelDownloaded = "未下载离线 TTS 模型，请前往「设置 → TTS 引擎管理」下载"
    static let engineNotReady = "离线引擎未就绪"
    static let initOom = "内存不足，无法加载离线模型，请关闭其他应用后重试"
    static let initFailed = "离线引擎加载失败，请检查模型文件是否完整或尝试重新下载"

    static func synthesisFailed(_ reason: String) -> String { "离线合成失败：\(reason)" }
    static func initLowMemory(_ mb: Int64) -> String {
        "内存不足，无法加载离线模型（需要约 \(mb)MB 空闲内存）"
    }
    static func initFailedDetail(_ detail: String) -> String { "离线引擎加载失败：\(detail)" }
    static func startupInitSherpa(_ name: String) -> String { "正在加载离线模型：\(name)…" }
}
