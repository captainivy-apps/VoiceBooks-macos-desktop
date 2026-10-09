import Foundation
import Combine

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var books: [BookWithProgress] = []
    @Published var sortBy: SortBy = .lastPlayed
    @Published var sortOrder: SortOrder = .desc
    @Published var selectionMode = false
    @Published var selectedIds = Set<String>()
    @Published var isImporting = false
    @Published var importSummary: String?
    @Published var rebuildProgress = LibraryRebuildProgress()
    @Published var isRebuilding = false

    private let services: AppServices
    private var pollTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        sortBy = AppSettings.sortBy
        sortOrder = AppSettings.sortOrder
    }

    func load() async {
        await refresh()
    }

    func refresh() async {
        let all = (try? await services.bookRepository.allBooks()) ?? []
        books = sort(all)
        managePolling()
    }

    private func sort(_ all: [BookWithProgress]) -> [BookWithProgress] {
        let sorted: [BookWithProgress]
        switch sortBy {
        case .uploadTime:
            sorted = all.sorted { $0.uploadTime < $1.uploadTime }
        case .lastPlayed:
            sorted = all.sorted { ($0.lastPlayedTime ?? 0) < ($1.lastPlayedTime ?? 0) }
        }
        return sortOrder == .desc ? sorted.reversed() : sorted
    }

    func setSort(_ by: SortBy, _ order: SortOrder) {
        sortBy = by
        sortOrder = order
        AppSettings.sortBy = by
        AppSettings.sortOrder = order
        books = sort(books)
    }

    func toggleSelectionMode() {
        selectionMode.toggle()
        if !selectionMode { selectedIds.removeAll() }
    }

    func toggleSelection(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    func selectAll(_ books: [BookWithProgress]) {
        selectedIds = Set(books.map { $0.id })
    }

    func deleteBook(_ id: String) async {
        await services.bookRepository.deleteBook(id)
        if PlaybackController.shared.snapshot.bookId == id {
            services.playbackEngine.stop()
        }
        await refresh()
    }

    func deleteSelected() async {
        let ids = Array(selectedIds)
        guard !ids.isEmpty else { return }
        await services.bookRepository.deleteBooks(ids)
        if ids.contains(PlaybackController.shared.snapshot.bookId) {
            services.playbackEngine.stop()
        }
        selectedIds.removeAll()
        selectionMode = false
        await refresh()
    }

    func retryImport(_ id: String) async {
        await services.bookRepository.retryImport(bookId: id)
        await refresh()
    }

    func refreshMetadata(_ id: String) async {
        _ = try? await services.bookRepository.refreshBookMetadata(bookId: id)
        await refresh()
    }

    func importLocalFiles(_ files: [URL]) async {
        guard !files.isEmpty else {
            AppNotifier.shared.show("仅支持 EPUB 格式电子书")
            return
        }
        isImporting = true
        defer { isImporting = false }
        var started = 0, duplicates = 0, failed = 0
        var batch: Set<String>? = nil
        for file in files {
            guard EbookUrlHelper.isSupportedExtension(EbookUrlHelper.extensionOf(file.lastPathComponent)) else {
                failed += 1
                continue
            }
            let staged = (try? await services.bookRepository.stageIncomingFile(source: file, fileName: file.lastPathComponent)) ?? file
            let result = await services.bookRepository.importFromLocalFile(
                file: staged,
                fileName: file.lastPathComponent,
                sourceUrl: nil,
                batchMd5s: &batch,
                deleteSourceOnFinish: true
            )
            switch result {
            case .started: started += 1
            case .duplicate: duplicates += 1
            case .failed: failed += 1
            }
        }
        importSummary = "导入完成：\(started) 本已开始，\(duplicates) 本重复跳过，\(failed) 本失败"
        AppNotifier.shared.show(importSummary ?? "已开始导入", long: true)
        await refresh()
    }

    func importFromUrl(_ url: String) async {
        isImporting = true
        defer { isImporting = false }
        let result = await services.bookRepository.importFromUrl(url)
        switch result {
        case .started: AppNotifier.shared.show("已开始导入")
        case .duplicate(let title): AppNotifier.shared.show("《\(title)》已存在，已跳过", long: true)
        case .failed(let message): AppNotifier.shared.show(message, long: true)
        }
        await refresh()
    }

    func rebuildLibrary() async {
        guard !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }
        await services.bookRepository.rebuildLibraryFromStorage { [weak self] progress in
            Task { @MainActor in
                self?.rebuildProgress = progress
                if !progress.isRunning {
                    Task { await self?.refresh() }
                }
            }
        }
        rebuildProgress = await services.bookRepository.currentRebuildProgress()
        await refresh()
    }

    private func managePolling() {
        let anyActive = books.contains {
            $0.statusEnum == .pending || $0.statusEnum == .processing
        }
        if anyActive {
            guard pollTask == nil else { return }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard let self, !Task.isCancelled else { return }
                    let all = (try? await self.services.bookRepository.allBooks()) ?? []
                    self.books = self.sort(all)
                    let stillActive = all.contains {
                        ($0.statusEnum == .pending || $0.statusEnum == .processing)
                    }
                    if !stillActive { break }
                }
                self?.pollTask = nil
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }
}
