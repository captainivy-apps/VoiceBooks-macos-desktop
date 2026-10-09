import Foundation

/// Runs the EPUB parse → text/cover → sentence index pipeline.
enum ImportPipeline {
    static func runImport(bookRepo: BookRepository, fileStorage: FileStorage, bookId: String) async {
        do {
            guard let book = try await bookRepo.getBook(bookId) else { return }
            await bookRepo.markImportProcessing(bookId)

            guard book.format == .epub else {
                throw ImportError.unsupportedFormat(book.format.rawValue.lowercased())
            }
            let parser = EpubParser()
            await bookRepo.updateImportProgress(bookId, progress: 5)
            let parsed = try parser.parse(file: URL(fileURLWithPath: book.sourcePath), format: book.format)
            await bookRepo.updateImportProgress(bookId, progress: 45)

            guard !parsed.textContent.trimmed.isEmpty else {
                throw ImportError.emptyContent
            }

            let textFile = fileStorage.bookTextFile(bookId: bookId)
            try parsed.textContent.write(to: textFile, atomically: true, encoding: .utf8)
            await bookRepo.updateImportProgress(bookId, progress: 50)

            var coverPath: String?
            if let coverBytes = parsed.coverBytes {
                let coverFile = fileStorage.bookCoverFile(bookId: bookId)
                try? coverBytes.write(to: coverFile)
                coverPath = coverFile.path
            }

            await bookRepo.updateImportProgress(bookId, progress: 55)
            let sentences = SentenceSplitter.splitForImport(file: textFile)
            await bookRepo.updateImportProgress(bookId, progress: 70)

            let entities = sentences.map { slice in
                SentenceIndexEntity(
                    bookId: bookId,
                    sentenceIndex: slice.index,
                    byteOffsetStart: slice.byteOffsetStart,
                    byteOffsetEnd: slice.byteOffsetEnd,
                    textPreview: slice.textPreview
                )
            }
            await bookRepo.insertSentencesBatched(bookId: bookId, sentences: entities) { progress in
                Task { await bookRepo.updateImportProgress(bookId, progress: progress) }
            }

            await bookRepo.updateAfterImport(
                bookId: bookId,
                title: parsed.title,
                author: parsed.author.isEmpty ? "未知作者" : parsed.author,
                summary: String(parsed.summary.prefix(BookRepository.maxSummaryLength)),
                coverPath: coverPath,
                textPath: textFile.path,
                sentenceCount: sentences.count,
                publisher: parsed.publisher.isEmpty ? nil : parsed.publisher,
                publishedDate: parsed.publishedDate.isEmpty ? nil : parsed.publishedDate,
                language: parsed.language.isEmpty ? nil : parsed.language,
                isbn: parsed.isbn.isEmpty ? nil : parsed.isbn,
                subjects: parsed.subjects.isEmpty ? nil : parsed.subjects
            )
        } catch {
            Log.error("ImportPipeline", "Import failed for book \(bookId)", error)
            await bookRepo.markImportFailed(bookId, error: ImportErrorMessages.toUserMessage(error))
        }
    }
}
