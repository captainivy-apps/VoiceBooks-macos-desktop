import Foundation

enum RebuildStage: String {
    case idle = "IDLE"
    case preparing = "PREPARING"
    case scanning = "SCANNING"
    case rebuilding = "REBUILDING"
    case completed = "COMPLETED"
}

struct LibraryRebuildProgress: Equatable {
    var isRunning: Bool = false
    var stage: RebuildStage = .idle
    var totalFiles: Int = 0
    var processedFiles: Int = 0
    var successCount: Int = 0
    var failedCount: Int = 0
    var currentFileName: String? = nil
    var message: String? = nil
}

/// Orchestrates book files + database, ported from the Kotlin `BookRepository`.
actor BookRepository {
    static let maxSummaryLength = 2048
    private static let sentenceInsertBatchSize = 500

    private let bookStore: BookStore
    private let fileStorage: FileStorage
    private let cacheDir: URL
    private let epubParser = EpubParser()
    private let downloader = EbookDownloader()

    private var enqueueImport: ((String) -> Void)?
    private var enqueueUrlImport: ((String, String) -> Void)?
    private var rebuildProgress = LibraryRebuildProgress()

    init(bookStore: BookStore, fileStorage: FileStorage, cacheDir: URL) {
        self.bookStore = bookStore
        self.fileStorage = fileStorage
        self.cacheDir = cacheDir
    }

    func setImportRunners(
        enqueueImport: @escaping (String) -> Void,
        enqueueUrlImport: @escaping (String, String) -> Void
    ) {
        self.enqueueImport = enqueueImport
        self.enqueueUrlImport = enqueueUrlImport
    }

    // MARK: - Queries

    func allBooks() async throws -> [BookWithProgress] {
        try await bookStore.allBooks()
    }

    func getBook(_ bookId: String) async throws -> BookEntity? {
        try await bookStore.getBook(bookId)
    }

    func getSentences(_ bookId: String) async throws -> [SentenceIndexEntity] {
        try await bookStore.getSentences(bookId)
    }

    func getProgress(_ bookId: String) async throws -> PlaybackProgressEntity? {
        try await bookStore.getProgress(bookId)
    }

    func healOversizedBookRows() async {
        try? await bookStore.truncateOversizedTextColumns()
    }

    func saveProgress(_ bookId: String, sentenceIndex: Int, positionMs: Int64) async {
        try? await bookStore.saveProgress(bookId, sentenceIndex: sentenceIndex, positionMs: positionMs)
    }

    func currentRebuildProgress() -> LibraryRebuildProgress { rebuildProgress }

    // MARK: - Staging

    func stageIncomingFile(source: URL, fileName: String) throws -> URL {
        Paths.createIfNeeded(cacheDir)
        let tempFile = cacheDir.appendingPathComponent("\(Int64(Date().timeIntervalSince1970 * 1000))_\(fileName)")
        if FileManager.default.fileExists(atPath: tempFile.path) {
            try? FileManager.default.removeItem(at: tempFile)
        }
        try FileManager.default.copyItem(at: source, to: tempFile)
        return tempFile
    }

    // MARK: - Import

    func importFromLocalFile(
        file: URL,
        fileName: String,
        sourceUrl: String? = nil,
        batchMd5s: inout Set<String>?,
        deleteSourceOnFinish: Bool = false
    ) async -> ImportResult {
        let ext = EbookUrlHelper.extensionOf(fileName)
        let format = Self.extensionToFormat(ext)
        let title = fileName.substringBeforeLast(".")

        do {
            if format == .unknown {
                throw ImportError.unsupportedFormat(ext)
            }
            guard let md5 = MD5Hasher.md5(ofFile: file) else {
                throw ImportError.readFile
            }
            if let existing = try? await bookStore.getBookByContentMd5(md5) {
                if deleteSourceOnFinish { try? FileManager.default.removeItem(at: file) }
                return .duplicate(existingTitle: existing.title)
            }
            if batchMd5s?.contains(md5) == true {
                if deleteSourceOnFinish { try? FileManager.default.removeItem(at: file) }
                return .duplicate(existingTitle: title)
            }
            batchMd5s?.insert(md5)

            let bookId = fileStorage.newBookId()
            let sourceFile = fileStorage.bookSourceFile(bookId: bookId, extension: ext)
            if file.standardizedFileURL != sourceFile.standardizedFileURL {
                if FileManager.default.fileExists(atPath: sourceFile.path) {
                    try? FileManager.default.removeItem(at: sourceFile)
                }
                try FileManager.default.copyItem(at: file, to: sourceFile)
                if deleteSourceOnFinish { try? FileManager.default.removeItem(at: file) }
            }

            try await startImport(
                bookId: bookId, title: title, format: format,
                sourcePath: sourceFile.path, sourceUrl: sourceUrl, contentMd5: md5,
                enqueue: { self.enqueueImport?($0) }
            )
            return .started(bookId: bookId)
        } catch {
            if deleteSourceOnFinish { try? FileManager.default.removeItem(at: file) }
            let bookId = fileStorage.newBookId()
            await handleImportFailure(bookId: bookId, title: title, format: format, error: error)
            return .failed(message: ImportErrorMessages.toUserMessage(error))
        }
    }

    func importFromUrl(_ url: String) async -> ImportResult {
        let trimmedUrl = url.trimmed
        let bookId = fileStorage.newBookId()

        guard EbookUrlHelper.isValidHttpUrl(trimmedUrl) else {
            await handleImportFailure(bookId: bookId, title: trimmedUrl, format: .unknown, error: ImportError.invalidUrl)
            return .failed(message: AppMessages.importErrorInvalidUrl)
        }
        guard let ext = EbookUrlHelper.extensionFromUrl(trimmedUrl) else {
            return .failed(message: AppMessages.unsupportedFormat("未知"))
        }
        let format = Self.extensionToFormat(ext)
        guard format != .unknown else {
            return .failed(message: AppMessages.unsupportedFormat(ext))
        }
        let fileName = EbookUrlHelper.fileNameFromUrlPath(trimmedUrl)
        let title = fileName.substringBeforeLast(".").isEmpty ? fileName : fileName.substringBeforeLast(".")
        let sourceFile = fileStorage.bookSourceFile(bookId: bookId, extension: ext)

        do {
            try await startImport(
                bookId: bookId, title: title, format: format,
                sourcePath: sourceFile.path, sourceUrl: trimmedUrl, contentMd5: nil,
                enqueue: { self.enqueueUrlImport?($0, trimmedUrl) }
            )
            return .started(bookId: bookId)
        } catch {
            await handleImportFailure(bookId: bookId, title: title, format: format, error: error)
            return .failed(message: ImportErrorMessages.toUserMessage(error))
        }
    }

    /// Downloads the URL import payload, dedupes and enqueues the local parse.
    func runUrlImport(bookId: String, url: String) async {
        guard let book = try? await bookStore.getBook(bookId) else { return }
        try? await bookStore.updateImportStatus(bookId, status: .processing, error: nil)

        let ext = EbookUrlHelper.extensionFromUrl(url)
            ?? EbookUrlHelper.extensionOf(book.sourcePath)
            ?? "tmp"
        var target = URL(fileURLWithPath: book.sourcePath)
        if book.sourcePath.isEmpty || !FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) {
            target = fileStorage.bookSourceFile(bookId: bookId, extension: ext)
        }
        Paths.createIfNeeded(target.deletingLastPathComponent())

        let result = await downloader.download(url: url, targetFile: target) { progress in
            Task { try? await self.bookStore.updateImportProgress(bookId, progress: progress) }
        }

        switch result {
        case .success(let fileName):
            let resolvedExt = EbookUrlHelper.extensionOf(fileName)
            guard resolvedExt != "unknown", !resolvedExt.isEmpty, EbookUrlHelper.isSupportedExtension(resolvedExt) else {
                try? FileManager.default.removeItem(at: target)
                try? await bookStore.updateImportStatus(bookId, status: .failed, error: AppMessages.unsupportedFormat("?"))
                return
            }
            let desired = fileStorage.bookSourceFile(bookId: bookId, extension: resolvedExt)
            if target.standardizedFileURL != desired.standardizedFileURL {
                if FileManager.default.fileExists(atPath: desired.path) {
                    try? FileManager.default.removeItem(at: desired)
                }
                try? FileManager.default.moveItem(at: target, to: desired)
                target = desired
            }
            _ = await finalizeUrlImport(bookId: bookId, sourceFile: target, format: Self.extensionToFormat(resolvedExt))
        case .failure(let error):
            try? FileManager.default.removeItem(at: target)
            try? await bookStore.updateImportStatus(
                bookId, status: .failed, error: ImportErrorMessages.downloadErrorMessage(error)
            )
        }
    }

    func finalizeUrlImport(bookId: String, sourceFile: URL, format: BookFormat) async -> ImportResult {
        guard let md5 = MD5Hasher.md5(ofFile: sourceFile) else {
            return .failed(message: AppMessages.importErrorReadFile)
        }
        if let existing = try? await bookStore.getBookByContentMd5(md5) {
            try? FileManager.default.removeItem(at: sourceFile)
            try? await bookStore.deleteBook(bookId)
            return .duplicate(existingTitle: existing.title)
        }
        do {
            try await bookStore.updateContentMd5(bookId, md5: md5)
        } catch {
            if Self.isUniqueConstraintViolation(error) {
                let existing = try? await bookStore.getBookByContentMd5(md5)
                try? FileManager.default.removeItem(at: sourceFile)
                try? await bookStore.deleteBook(bookId)
                return .duplicate(existingTitle: existing?.title ?? sourceFile.deletingPathExtension().lastPathComponent)
            }
            return .failed(message: ImportErrorMessages.toUserMessage(error))
        }
        try? await bookStore.updateSourceFile(bookId, sourcePath: sourceFile.path, format: format)
        enqueueImport?(bookId)
        return .started(bookId: bookId)
    }

    func retryImport(bookId: String) async {
        guard let book = try? await bookStore.getBook(bookId) else { return }
        guard book.format == .epub else {
            try? await bookStore.updateImportStatus(bookId, status: .failed, error: AppMessages.unsupportedFormat(book.format.rawValue))
            return
        }
        if !book.sourcePath.isEmpty, FileManager.default.fileExists(atPath: book.sourcePath) {
            try? await bookStore.updateImportStatus(bookId, status: .pending, error: nil)
            enqueueImport?(bookId)
            return
        }
        let sourceUrl = (book.sourceUrl ?? "").trimmed
        if !sourceUrl.isEmpty {
            try? await bookStore.updateImportStatus(bookId, status: .pending, error: nil)
            enqueueUrlImport?(bookId, sourceUrl)
            return
        }
        try? await bookStore.updateImportStatus(bookId, status: .failed, error: AppMessages.importErrorSourceMissing)
    }

    // MARK: - Library rebuild

    func rebuildLibraryFromStorage(onProgress: @escaping (LibraryRebuildProgress) -> Void) async {
        guard !rebuildProgress.isRunning else { return }
        rebuildProgress = LibraryRebuildProgress(isRunning: true, stage: .preparing, message: "preparing")
        onProgress(rebuildProgress)
        do {
            try await bookStore.clearDuplicateIndexAndMetadata()
            rebuildProgress.stage = .scanning
            rebuildProgress.message = "scanning"
            onProgress(rebuildProgress)

            let files: [URL] = {
                let contents = (try? FileManager.default.contentsOfDirectory(at: fileStorage.booksDir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
                return contents
                    .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                    .filter { Self.extensionToFormat(EbookUrlHelper.extensionOf($0.lastPathComponent)) != .unknown }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }()

            rebuildProgress.stage = .rebuilding
            rebuildProgress.totalFiles = files.count
            rebuildProgress.message = "rebuilding"
            onProgress(rebuildProgress)

            var processed = 0, success = 0, failed = 0
            for file in files {
                rebuildProgress.currentFileName = file.lastPathComponent
                rebuildProgress.processedFiles = processed
                rebuildProgress.successCount = success
                rebuildProgress.failedCount = failed
                onProgress(rebuildProgress)

                let result = await rebuildSingleFile(file)
                switch result {
                case .started, .duplicate: success += 1
                case .failed: failed += 1
                }
                processed += 1
                rebuildProgress.processedFiles = processed
                rebuildProgress.successCount = success
                rebuildProgress.failedCount = failed
                onProgress(rebuildProgress)
            }

            rebuildProgress.isRunning = false
            rebuildProgress.stage = .completed
            rebuildProgress.currentFileName = nil
            rebuildProgress.message = "completed"
            onProgress(rebuildProgress)
        } catch {
            rebuildProgress.isRunning = false
            rebuildProgress.stage = .completed
            rebuildProgress.currentFileName = nil
            rebuildProgress.message = (error as NSError).localizedDescription
            onProgress(rebuildProgress)
        }
    }

    private func rebuildSingleFile(_ file: URL) async -> ImportResult {
        let ext = EbookUrlHelper.extensionOf(file.lastPathComponent)
        let format = Self.extensionToFormat(ext)
        guard format != .unknown else { return .failed(message: AppMessages.unsupportedFormat(ext)) }

        if let existing = try? await bookStore.getBookBySourcePath(file.path) {
            if let md5 = MD5Hasher.md5(ofFile: file) {
                try? await bookStore.updateContentMd5(existing.id, md5: md5)
            }
            await retryImport(bookId: existing.id)
            return .started(bookId: existing.id)
        }
        var batch: Set<String>? = nil
        return await importFromLocalFile(
            file: file, fileName: file.lastPathComponent, sourceUrl: nil,
            batchMd5s: &batch, deleteSourceOnFinish: false
        )
    }

    // MARK: - Metadata refresh

    @discardableResult
    func refreshBookMetadata(bookId: String) async throws -> BookEntity {
        guard let book = try await bookStore.getBook(bookId) else {
            throw ImportError.generic("Book not found")
        }
        guard !book.sourcePath.isEmpty, FileManager.default.fileExists(atPath: book.sourcePath) else {
            throw ImportError.sourceMissing
        }
        guard book.format == .epub else {
            throw ImportError.unsupportedFormat(book.format.rawValue)
        }
        let parsed = try epubParser.parse(file: URL(fileURLWithPath: book.sourcePath), format: book.format)

        var coverPath = book.coverPath
        if let coverBytes = parsed.coverBytes {
            let coverFile = fileStorage.bookCoverFile(bookId: bookId)
            try? coverBytes.write(to: coverFile)
            coverPath = coverFile.path
        }

        try await bookStore.updateBookMetadata(
            bookId: bookId,
            title: parsed.title,
            author: parsed.author.isEmpty ? "未知作者" : parsed.author,
            summary: String(parsed.summary.prefix(Self.maxSummaryLength)),
            coverPath: coverPath,
            publisher: parsed.publisher.isEmpty ? nil : parsed.publisher,
            publishedDate: parsed.publishedDate.isEmpty ? nil : parsed.publishedDate,
            language: parsed.language.isEmpty ? nil : parsed.language,
            isbn: parsed.isbn.isEmpty ? nil : parsed.isbn,
            subjects: parsed.subjects.isEmpty ? nil : parsed.subjects
        )
        guard let updated = try await bookStore.getBook(bookId) else {
            throw ImportError.generic("Book not found")
        }
        return updated
    }

    // MARK: - Post-import / status

    func updateAfterImport(
        bookId: String, title: String, author: String, summary: String, coverPath: String?,
        textPath: String, sentenceCount: Int, publisher: String?, publishedDate: String?,
        language: String?, isbn: String?, subjects: String?
    ) async {
        try? await bookStore.updateBookAfterImport(
            bookId: bookId, title: title, author: author, summary: summary, coverPath: coverPath,
            textPath: textPath, sentenceCount: sentenceCount, publisher: publisher,
            publishedDate: publishedDate, language: language, isbn: isbn, subjects: subjects,
            status: .completed
        )
    }

    func markImportFailed(_ bookId: String, error: String) async {
        try? await bookStore.updateImportStatus(bookId, status: .failed, error: error)
    }

    func markImportProcessing(_ bookId: String) async {
        try? await bookStore.updateImportStatus(bookId, status: .processing, error: nil)
    }

    func updateImportProgress(_ bookId: String, progress: Int) async {
        try? await bookStore.updateImportProgress(bookId, progress: max(0, min(100, progress)))
    }

    func insertSentencesBatched(
        bookId: String,
        sentences: [SentenceIndexEntity],
        onProgress: @escaping (Int) -> Void
    ) async {
        try? await bookStore.deleteSentences(bookId)
        guard !sentences.isEmpty else { return }
        let batches = stride(from: 0, to: sentences.count, by: Self.sentenceInsertBatchSize).map {
            Array(sentences[$0..<min($0 + Self.sentenceInsertBatchSize, sentences.count)])
        }
        for (index, batch) in batches.enumerated() {
            try? await bookStore.insertSentences(batch)
            let progress = 70 + (25 * (index + 1) / batches.count)
            onProgress(progress)
        }
    }

    func readSentenceText(textPath: String, byteOffsetStart: Int, byteOffsetEnd: Int) -> String {
        guard !textPath.isEmpty, FileManager.default.fileExists(atPath: textPath) else { return "" }
        let start = max(0, byteOffsetStart)
        let end = max(start, byteOffsetEnd)
        let length = end - start
        guard length > 0 else { return "" }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: textPath)) else { return "" }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(start))
            guard let data = try handle.read(upToCount: length), data.count == length else { return "" }
            return String(decoding: data, as: UTF8.self).trimmed
        } catch {
            return ""
        }
    }

    // MARK: - Delete

    func deleteBook(_ bookId: String) async {
        try? await bookStore.deleteBook(bookId)
        fileStorage.deleteBookFiles(bookId: bookId)
    }

    func deleteBooks(_ bookIds: [String]) async {
        guard !bookIds.isEmpty else { return }
        try? await bookStore.deleteBooks(bookIds)
        fileStorage.deleteBooksFiles(bookIds)
    }

    // MARK: - Private

    private func startImport(
        bookId: String, title: String, format: BookFormat, sourcePath: String,
        sourceUrl: String?, contentMd5: String?, enqueue: (String) -> Void
    ) async throws {
        let book = BookEntity(
            id: bookId, title: title, author: "", summary: "", coverPath: nil,
            sourcePath: sourcePath, textPath: "", format: format,
            uploadTime: Int64(Date().timeIntervalSince1970 * 1000), lastPlayedTime: nil,
            sentenceCount: 0, importStatus: .pending, importError: nil, importProgress: 0,
            sourceUrl: sourceUrl, publisher: nil, publishedDate: nil, language: nil,
            isbn: nil, subjects: nil, contentMd5: contentMd5
        )
        try await bookStore.insertBook(book)
        enqueue(bookId)
    }

    private func handleImportFailure(bookId: String, title: String, format: BookFormat, error: Error) async {
        let message = ImportErrorMessages.toUserMessage(error)
        let failedBook = BookEntity(
            id: bookId, title: title, author: "", summary: "", coverPath: nil,
            sourcePath: "", textPath: "", format: format,
            uploadTime: Int64(Date().timeIntervalSince1970 * 1000), lastPlayedTime: nil,
            sentenceCount: 0, importStatus: .failed, importError: message, importProgress: 0,
            sourceUrl: nil, publisher: nil, publishedDate: nil, language: nil,
            isbn: nil, subjects: nil, contentMd5: nil
        )
        try? await bookStore.insertBook(failedBook)
    }

    static func extensionToFormat(_ ext: String) -> BookFormat {
        ext.lowercased() == "epub" ? .epub : .unknown
    }

    private static func isUniqueConstraintViolation(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription
        return message.localizedCaseInsensitiveContains("UNIQUE constraint failed")
            || (String(describing: type(of: error)).localizedCaseInsensitiveContains("sqlite")
                && message.localizedCaseInsensitiveContains("unique"))
    }
}
