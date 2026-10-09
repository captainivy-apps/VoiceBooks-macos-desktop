import Foundation

enum BookFormat: String, CaseIterable {
    case epub
    case txt
    case mobi
    case azw
    case azw3
    case unknown

    var displayName: String { rawValue.uppercased() }
}

enum ImportStatus: String {
    case pending = "PENDING"
    case processing = "PROCESSING"
    case completed = "COMPLETED"
    case failed = "FAILED"
}

enum SortBy: String {
    case uploadTime = "UPLOAD_TIME"
    case lastPlayed = "LAST_PLAYED"
}

enum SortOrder: String {
    case asc = "ASC"
    case desc = "DESC"
}

enum TtsModelFamily: String {
    case vits
    case kokoro
    case kitten

    static func from(modelType: String) -> TtsModelFamily {
        switch modelType {
        case "kokoro": return .kokoro
        case "kitten": return .kitten
        default: return .vits
        }
    }
}

enum TtsDownloadState: String {
    case notDownloaded = "NOT_DOWNLOADED"
    case downloading = "DOWNLOADING"
    case downloaded = "DOWNLOADED"
    case failed = "FAILED"
}

struct ParsedBook {
    var title: String
    var author: String
    var summary: String
    var textContent: String
    var coverBytes: Data?
    var publisher: String = ""
    var publishedDate: String = ""
    var language: String = ""
    var isbn: String = ""
    var subjects: String = ""
}

struct SentenceChunk {
    let index: Int
    let byteOffsetStart: Int
    let byteOffsetEnd: Int
    let text: String
}

/// Lightweight import-time sentence index; holds byte offsets and a short preview only.
struct SentenceIndexSlice {
    let index: Int
    let byteOffsetStart: Int
    let byteOffsetEnd: Int
    let textPreview: String
}

struct TtsModelInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let language: String
    let sizeBytes: Int64
    let downloadUrl: String
    var mirrorDownloadUrl: String? = nil
    var modelType: String = "vits"
    var family: TtsModelFamily = .vits
    var speakerId: Int = 0
    var speakerCount: Int = 1
    var voicesFile: String = "voices.bin"

    init(
        id: String,
        name: String,
        language: String,
        sizeBytes: Int64,
        downloadUrl: String,
        mirrorDownloadUrl: String? = nil,
        modelType: String = "vits",
        family: TtsModelFamily = .vits,
        speakerId: Int = 0,
        speakerCount: Int = 1,
        voicesFile: String = "voices.bin"
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.sizeBytes = sizeBytes
        self.downloadUrl = downloadUrl
        self.mirrorDownloadUrl = mirrorDownloadUrl
        self.modelType = modelType
        self.family = family
        self.speakerId = speakerId
        self.speakerCount = speakerCount
        self.voicesFile = voicesFile
    }
}

struct TtsModelBenchmark {
    let modelId: String
    let speakerId: Int
    let synthesisMs: Int64
    let audioDurationMs: Int64
    let rtf: Float
    let sampleRate: Int
    let benchmarkedAt: Int64
}

/// Result of an import request (used by the import pipeline / callers).
enum ImportResult {
    case started(bookId: String)
    case duplicate(existingTitle: String)
    case failed(message: String)
}
