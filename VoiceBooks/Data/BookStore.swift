import Foundation

/// Actor-confined data access for books, sentence index and playback progress.
actor BookStore {
    private let db: AppDatabase
    private var sqlite: SQLiteDatabase { db.sqlite }

    init(database: AppDatabase) {
        self.db = database
    }

    // MARK: - Queries

    func allBooks() throws -> [BookWithProgress] {
        var result: [BookWithProgress] = []
        try sqlite.query("""
        SELECT b.id, b.title, b.author, b.coverPath, b.uploadTime, b.lastPlayedTime,
               b.sentenceCount, b.importStatus, b.importError, b.importProgress, b.sourceUrl,
               p.currentSentenceIndex, p.positionInSentenceMs
        FROM books b
        LEFT JOIN playback_progress p ON b.id = p.bookId
        """) { row in
            result.append(BookWithProgress(
                id: row.string(0),
                title: row.string(1),
                author: row.string(2),
                coverPath: row.optionalString(3),
                uploadTime: row.int64(4),
                lastPlayedTime: row.optionalInt64(5),
                sentenceCount: row.int(6),
                importStatus: row.string(7),
                importError: row.optionalString(8),
                importProgress: row.int(9),
                sourceUrl: row.optionalString(10),
                currentSentenceIndex: row.optionalInt64(11).map { Int($0) },
                positionInSentenceMs: row.optionalInt64(12)
            ))
        }
        return result
    }

    func getBook(_ bookId: String) throws -> BookEntity? {
        try sqlite.queryValue("SELECT \(Self.bookColumns) FROM books WHERE id = ? LIMIT 1", [.text(bookId)]) {
            Self.mapBook($0)
        }
    }

    func getBookByContentMd5(_ md5: String) throws -> BookEntity? {
        try sqlite.queryValue("SELECT \(Self.bookColumns) FROM books WHERE contentMd5 = ? LIMIT 1", [.text(md5)]) {
            Self.mapBook($0)
        }
    }

    func getBookBySourcePath(_ sourcePath: String) throws -> BookEntity? {
        try sqlite.queryValue("SELECT \(Self.bookColumns) FROM books WHERE sourcePath = ? LIMIT 1", [.text(sourcePath)]) {
            Self.mapBook($0)
        }
    }

    func getContentMd5sForBooks(_ bookIds: [String]) throws -> [String] {
        guard !bookIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: bookIds.count).joined(separator: ",")
        var result: [String] = []
        try sqlite.query(
            "SELECT contentMd5 FROM books WHERE id IN (\(placeholders)) AND contentMd5 IS NOT NULL",
            bookIds.map { .text($0) }
        ) { result.append($0.string(0)) }
        return result
    }

    func getAllBookMd5Entries() throws -> [BookMd5Entry] {
        var result: [BookMd5Entry] = []
        try sqlite.query("SELECT id, contentMd5 FROM books") { row in
            result.append(BookMd5Entry(id: row.string(0), contentMd5: row.optionalString(1)))
        }
        return result
    }

    // MARK: - Mutations

    func insertBook(_ book: BookEntity) throws {
        try sqlite.run("""
        INSERT OR REPLACE INTO books
        (id, title, author, summary, coverPath, sourcePath, textPath, format, uploadTime,
         lastPlayedTime, sentenceCount, importStatus, importError, importProgress, sourceUrl,
         publisher, publishedDate, language, isbn, subjects, contentMd5)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, Self.bookValues(book))
    }

    func updateImportStatus(_ bookId: String, status: ImportStatus, error: String?) throws {
        try sqlite.run(
            "UPDATE books SET importStatus = ?, importError = ?, importProgress = 0 WHERE id = ?",
            [.text(status.rawValue), error.map { .text($0) } ?? .null, .text(bookId)]
        )
    }

    func updateImportProgress(_ bookId: String, progress: Int) throws {
        try sqlite.run(
            "UPDATE books SET importProgress = ? WHERE id = ?",
            [.integer(Int64(max(0, min(100, progress)))), .text(bookId)]
        )
    }

    func updateSourceFile(_ bookId: String, sourcePath: String, format: BookFormat) throws {
        try sqlite.run(
            "UPDATE books SET sourcePath = ?, format = ? WHERE id = ?",
            [.text(sourcePath), .text(format.rawValue), .text(bookId)]
        )
    }

    func updateBookAfterImport(
        bookId: String,
        title: String,
        author: String,
        summary: String,
        coverPath: String?,
        textPath: String,
        sentenceCount: Int,
        publisher: String?,
        publishedDate: String?,
        language: String?,
        isbn: String?,
        subjects: String?,
        status: ImportStatus
    ) throws {
        try sqlite.run("""
        UPDATE books SET title = ?, author = ?, summary = ?, coverPath = ?, textPath = ?,
        sentenceCount = ?, publisher = ?, publishedDate = ?, language = ?, isbn = ?, subjects = ?,
        importStatus = ?, importError = NULL, importProgress = 0 WHERE id = ?
        """, [
            .text(title), .text(author), .text(summary),
            coverPath.map { .text($0) } ?? .null, .text(textPath), .integer(Int64(sentenceCount)),
            publisher.map { .text($0) } ?? .null, publishedDate.map { .text($0) } ?? .null,
            language.map { .text($0) } ?? .null, isbn.map { .text($0) } ?? .null,
            subjects.map { .text($0) } ?? .null, .text(status.rawValue), .text(bookId),
        ])
    }

    func updateLastPlayed(_ bookId: String, time: Int64) throws {
        try sqlite.run("UPDATE books SET lastPlayedTime = ? WHERE id = ?", [.integer(time), .text(bookId)])
    }

    func updateBookMetadata(
        bookId: String,
        title: String,
        author: String,
        summary: String,
        coverPath: String?,
        publisher: String?,
        publishedDate: String?,
        language: String?,
        isbn: String?,
        subjects: String?
    ) throws {
        try sqlite.run("""
        UPDATE books SET title = ?, author = ?, summary = ?, coverPath = ?, publisher = ?,
        publishedDate = ?, language = ?, isbn = ?, subjects = ? WHERE id = ?
        """, [
            .text(title), .text(author), .text(summary),
            coverPath.map { .text($0) } ?? .null,
            publisher.map { .text($0) } ?? .null, publishedDate.map { .text($0) } ?? .null,
            language.map { .text($0) } ?? .null, isbn.map { .text($0) } ?? .null,
            subjects.map { .text($0) } ?? .null, .text(bookId),
        ])
    }

    func updateContentMd5(_ bookId: String, md5: String) throws {
        try sqlite.run("UPDATE books SET contentMd5 = ? WHERE id = ?", [.text(md5), .text(bookId)])
    }

    func clearDuplicateIndexAndMetadata() throws {
        try sqlite.run("""
        UPDATE books SET
        contentMd5 = NULL, title = '', author = '', summary = '', coverPath = NULL,
        publisher = NULL, publishedDate = NULL, language = NULL, isbn = NULL, subjects = NULL
        """)
    }

    func truncateOversizedTextColumns() throws {
        try sqlite.run("""
        UPDATE books SET
        title = CASE WHEN LENGTH(title) > 256 THEN SUBSTR(title, 1, 256) ELSE title END,
        author = CASE WHEN LENGTH(author) > 128 THEN SUBSTR(author, 1, 128) ELSE author END,
        coverPath = CASE WHEN LENGTH(coverPath) > 1024 THEN SUBSTR(coverPath, 1, 1024) ELSE coverPath END,
        summary = CASE WHEN LENGTH(summary) > 2048 THEN SUBSTR(summary, 1, 2048) ELSE summary END,
        importError = CASE WHEN LENGTH(importError) > 1024 THEN SUBSTR(importError, 1, 1024) ELSE importError END,
        sourceUrl = CASE WHEN LENGTH(sourceUrl) > 512 THEN SUBSTR(sourceUrl, 1, 512) ELSE sourceUrl END,
        sourcePath = CASE WHEN LENGTH(sourcePath) > 1024 THEN SUBSTR(sourcePath, 1, 1024) ELSE sourcePath END,
        textPath = CASE WHEN LENGTH(textPath) > 1024 THEN SUBSTR(textPath, 1, 1024) ELSE textPath END,
        publisher = CASE WHEN LENGTH(publisher) > 128 THEN SUBSTR(publisher, 1, 128) ELSE publisher END,
        subjects = CASE WHEN LENGTH(subjects) > 256 THEN SUBSTR(subjects, 1, 256) ELSE subjects END
        """)
    }

    func deleteBook(_ bookId: String) throws {
        try sqlite.run("DELETE FROM books WHERE id = ?", [.text(bookId)])
        try sqlite.run("DELETE FROM sentence_index WHERE bookId = ?", [.text(bookId)])
        try sqlite.run("DELETE FROM playback_progress WHERE bookId = ?", [.text(bookId)])
    }

    func deleteBooks(_ bookIds: [String]) throws {
        guard !bookIds.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: bookIds.count).joined(separator: ",")
        let params = bookIds.map { SQLiteValue.text($0) }
        try sqlite.run("DELETE FROM books WHERE id IN (\(placeholders))", params)
        try sqlite.run("DELETE FROM sentence_index WHERE bookId IN (\(placeholders))", params)
        try sqlite.run("DELETE FROM playback_progress WHERE bookId IN (\(placeholders))", params)
    }

    // MARK: - Sentence index

    func insertSentences(_ sentences: [SentenceIndexEntity]) throws {
        for sentence in sentences {
            try sqlite.run("""
            INSERT OR REPLACE INTO sentence_index
            (bookId, sentenceIndex, byteOffsetStart, byteOffsetEnd, textPreview)
            VALUES (?,?,?,?,?)
            """, [
                .text(sentence.bookId), .integer(Int64(sentence.sentenceIndex)),
                .integer(Int64(sentence.byteOffsetStart)), .integer(Int64(sentence.byteOffsetEnd)),
                .text(sentence.textPreview),
            ])
        }
    }

    func getSentences(_ bookId: String) throws -> [SentenceIndexEntity] {
        var result: [SentenceIndexEntity] = []
        try sqlite.query(
            "SELECT bookId, sentenceIndex, byteOffsetStart, byteOffsetEnd, textPreview FROM sentence_index WHERE bookId = ? ORDER BY sentenceIndex ASC",
            [.text(bookId)]
        ) { row in
            result.append(SentenceIndexEntity(
                bookId: row.string(0),
                sentenceIndex: row.int(1),
                byteOffsetStart: row.int(2),
                byteOffsetEnd: row.int(3),
                textPreview: row.string(4)
            ))
        }
        return result
    }

    func deleteSentences(_ bookId: String) throws {
        try sqlite.run("DELETE FROM sentence_index WHERE bookId = ?", [.text(bookId)])
    }

    // MARK: - Playback progress

    func saveProgress(_ bookId: String, sentenceIndex: Int, positionMs: Int64) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try sqlite.run("""
        INSERT OR REPLACE INTO playback_progress
        (bookId, currentSentenceIndex, positionInSentenceMs, updatedAt) VALUES (?,?,?,?)
        """, [.text(bookId), .integer(Int64(sentenceIndex)), .integer(positionMs), .integer(now)])
        try updateLastPlayed(bookId, time: now)
    }

    func getProgress(_ bookId: String) throws -> PlaybackProgressEntity? {
        try sqlite.queryValue(
            "SELECT bookId, currentSentenceIndex, positionInSentenceMs, updatedAt FROM playback_progress WHERE bookId = ?",
            [.text(bookId)]
        ) { row in
            PlaybackProgressEntity(
                bookId: row.string(0),
                currentSentenceIndex: row.int(1),
                positionInSentenceMs: row.int64(2),
                updatedAt: row.int64(3)
            )
        }
    }

    // MARK: - Mapping

    private static let bookColumns = """
    id, title, author, summary, coverPath, sourcePath, textPath, format, uploadTime,
    lastPlayedTime, sentenceCount, importStatus, importError, importProgress, sourceUrl,
    publisher, publishedDate, language, isbn, subjects, contentMd5
    """

    private static func mapBook(_ row: SQLiteRow) -> BookEntity {
        BookEntity(
            id: row.string(0),
            title: row.string(1),
            author: row.string(2),
            summary: row.string(3),
            coverPath: row.optionalString(4),
            sourcePath: row.string(5),
            textPath: row.string(6),
            format: BookFormat(rawValue: row.string(7)) ?? .unknown,
            uploadTime: row.int64(8),
            lastPlayedTime: row.optionalInt64(9),
            sentenceCount: row.int(10),
            importStatus: ImportStatus(rawValue: row.string(11)) ?? .pending,
            importError: row.optionalString(12),
            importProgress: row.int(13),
            sourceUrl: row.optionalString(14),
            publisher: row.optionalString(15),
            publishedDate: row.optionalString(16),
            language: row.optionalString(17),
            isbn: row.optionalString(18),
            subjects: row.optionalString(19),
            contentMd5: row.optionalString(20)
        )
    }

    private static func bookValues(_ book: BookEntity) -> [SQLiteValue] {
        [
            .text(book.id), .text(book.title), .text(book.author), .text(book.summary),
            book.coverPath.map { .text($0) } ?? .null, .text(book.sourcePath), .text(book.textPath),
            .text(book.format.rawValue), .integer(book.uploadTime),
            book.lastPlayedTime.map { .integer($0) } ?? .null,
            .integer(Int64(book.sentenceCount)), .text(book.importStatus.rawValue),
            book.importError.map { .text($0) } ?? .null, .integer(Int64(book.importProgress)),
            book.sourceUrl.map { .text($0) } ?? .null, book.publisher.map { .text($0) } ?? .null,
            book.publishedDate.map { .text($0) } ?? .null, book.language.map { .text($0) } ?? .null,
            book.isbn.map { .text($0) } ?? .null, book.subjects.map { .text($0) } ?? .null,
            book.contentMd5.map { .text($0) } ?? .null,
        ]
    }
}
