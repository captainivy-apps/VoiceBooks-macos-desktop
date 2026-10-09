import Foundation

struct BookEntity: Equatable {
    var id: String
    var title: String
    var author: String
    var summary: String
    var coverPath: String?
    var sourcePath: String
    var textPath: String
    var format: BookFormat
    var uploadTime: Int64
    var lastPlayedTime: Int64?
    var sentenceCount: Int
    var importStatus: ImportStatus
    var importError: String?
    var importProgress: Int
    var sourceUrl: String?
    var publisher: String?
    var publishedDate: String?
    var language: String?
    var isbn: String?
    var subjects: String?
    var contentMd5: String?
}

struct BookWithProgress: Identifiable, Equatable {
    var id: String
    var title: String
    var author: String
    var coverPath: String?
    var uploadTime: Int64
    var lastPlayedTime: Int64?
    var sentenceCount: Int
    var importStatus: String
    var importError: String?
    var importProgress: Int
    var sourceUrl: String?
    var currentSentenceIndex: Int?
    var positionInSentenceMs: Int64?

    var statusEnum: ImportStatus { ImportStatus(rawValue: importStatus) ?? .pending }
}

struct BookMd5Entry {
    var id: String
    var contentMd5: String?
}

struct SentenceIndexEntity {
    var bookId: String
    var sentenceIndex: Int
    var byteOffsetStart: Int
    var byteOffsetEnd: Int
    var textPreview: String
}

struct PlaybackProgressEntity {
    var bookId: String
    var currentSentenceIndex: Int
    var positionInSentenceMs: Int64
    var updatedAt: Int64
}

struct TtsModelEntity {
    var id: String
    var name: String
    var language: String
    var sizeBytes: Int64
    var downloadUrl: String
    var localPath: String?
    var downloadState: String
    var downloadError: String?
    var isDefault: Bool
    var modelType: String
    var speakerId: Int

    var stateEnum: TtsDownloadState { TtsDownloadState(rawValue: downloadState) ?? .notDownloaded }
}

struct TtsModelBenchmarkEntity {
    var modelId: String
    var speakerId: Int
    var synthesisMs: Int64
    var audioDurationMs: Int64
    var rtf: Float
    var sampleRate: Int
    var benchmarkedAt: Int64
}
