import Foundation

/// Owns the SQLite connection and creates the schema (idempotent DDL, matching
/// the Room schema used by the Kotlin desktop build).
final class AppDatabase {
    let sqlite: SQLiteDatabase

    init(url: URL) throws {
        sqlite = try SQLiteDatabase(url: url)
        try createSchema()
    }

    private func createSchema() throws {
        try sqlite.execute("PRAGMA foreign_keys = ON;")
        try sqlite.execute("""
        CREATE TABLE IF NOT EXISTS books (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL,
            author TEXT NOT NULL,
            summary TEXT NOT NULL,
            coverPath TEXT,
            sourcePath TEXT NOT NULL,
            textPath TEXT NOT NULL,
            format TEXT NOT NULL,
            uploadTime INTEGER NOT NULL,
            lastPlayedTime INTEGER,
            sentenceCount INTEGER NOT NULL,
            importStatus TEXT NOT NULL,
            importError TEXT,
            importProgress INTEGER NOT NULL DEFAULT 0,
            sourceUrl TEXT,
            publisher TEXT,
            publishedDate TEXT,
            language TEXT,
            isbn TEXT,
            subjects TEXT,
            contentMd5 TEXT
        );
        """)
        try sqlite.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_books_contentMd5 ON books(contentMd5);"
        )
        try sqlite.execute("""
        CREATE TABLE IF NOT EXISTS playback_progress (
            bookId TEXT NOT NULL PRIMARY KEY,
            currentSentenceIndex INTEGER NOT NULL,
            positionInSentenceMs INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL
        );
        """)
        try sqlite.execute("""
        CREATE TABLE IF NOT EXISTS sentence_index (
            bookId TEXT NOT NULL,
            sentenceIndex INTEGER NOT NULL,
            byteOffsetStart INTEGER NOT NULL,
            byteOffsetEnd INTEGER NOT NULL,
            textPreview TEXT NOT NULL,
            PRIMARY KEY (bookId, sentenceIndex)
        );
        """)
        try sqlite.execute("""
        CREATE TABLE IF NOT EXISTS tts_model_benchmarks (
            modelId TEXT NOT NULL,
            speakerId INTEGER NOT NULL,
            synthesisMs INTEGER NOT NULL,
            audioDurationMs INTEGER NOT NULL,
            rtf REAL NOT NULL,
            sampleRate INTEGER NOT NULL,
            benchmarkedAt INTEGER NOT NULL,
            PRIMARY KEY (modelId, speakerId)
        );
        """)
        try sqlite.execute("""
        CREATE TABLE IF NOT EXISTS tts_models (
            id TEXT NOT NULL PRIMARY KEY,
            name TEXT NOT NULL,
            language TEXT NOT NULL,
            sizeBytes INTEGER NOT NULL,
            downloadUrl TEXT NOT NULL,
            localPath TEXT,
            downloadState TEXT NOT NULL,
            downloadError TEXT,
            isDefault INTEGER NOT NULL,
            modelType TEXT NOT NULL,
            speakerId INTEGER NOT NULL
        );
        """)
    }
}
