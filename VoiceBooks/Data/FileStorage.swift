import Foundation

/// Manages the on-disk ebook storage layout (books / text / covers / tts_models).
final class FileStorage {
    private let root: URL

    init(root: URL) {
        self.root = root
        Paths.createIfNeeded(root)
    }

    var booksDir: URL { dir("books") }
    var coversDir: URL { dir("covers") }
    var ttsModelsDir: URL { dir("tts_models") }
    var textDir: URL { dir("text") }

    private func dir(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        Paths.createIfNeeded(url)
        return url
    }

    func newBookId() -> String { UUID().uuidString }

    func bookSourceFile(bookId: String, extension ext: String) -> URL {
        booksDir.appendingPathComponent("\(bookId).\(ext)")
    }

    func bookTextFile(bookId: String) -> URL {
        textDir.appendingPathComponent("\(bookId).txt")
    }

    func bookCoverFile(bookId: String) -> URL {
        coversDir.appendingPathComponent("\(bookId).jpg")
    }

    func ttsModelDir(modelId: String) -> URL {
        let url = ttsModelsDir.appendingPathComponent(modelId, isDirectory: true)
        Paths.createIfNeeded(url)
        return url
    }

    func ttsArchiveFile(modelId: String) -> URL {
        ttsModelsDir.appendingPathComponent("\(modelId).tar.bz2")
    }

    func deleteBookFiles(bookId: String) {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: booksDir, includingPropertiesForKeys: nil) {
            for file in contents where file.lastPathComponent.hasPrefix(bookId) {
                try? fm.removeItem(at: file)
            }
        }
        try? fm.removeItem(at: bookTextFile(bookId: bookId))
        try? fm.removeItem(at: bookCoverFile(bookId: bookId))
    }

    func deleteBooksFiles(_ bookIds: [String]) {
        bookIds.forEach { deleteBookFiles(bookId: $0) }
    }

    func deleteTtsModel(modelId: String) {
        try? FileManager.default.removeItem(at: ttsModelDir(modelId: modelId))
        try? FileManager.default.removeItem(at: ttsArchiveFile(modelId: modelId))
    }
}
