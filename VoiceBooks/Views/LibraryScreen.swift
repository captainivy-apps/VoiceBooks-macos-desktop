import SwiftUI
import AppKit

struct LibraryScreen: View {
    let services: AppServices
    @ObservedObject var libraryVM: LibraryViewModel
    @Binding var selectedBookId: String?

    @State private var showUrlSheet = false
    @State private var urlInput = ""
    @State private var showDeleteConfirm = false

    private let bookListWidth: CGFloat = 320

    var body: some View {
        HSplitView {
            bookListColumn
                .frame(minWidth: bookListWidth, idealWidth: bookListWidth, maxWidth: bookListWidth)
            BookDetailColumn(services: services, bookId: selectedBookId, libraryVM: libraryVM)
                .frame(minWidth: 460, maxWidth: .infinity)
        }
        .navigationTitle("书库")
        .sheet(isPresented: $showUrlSheet) { urlSheet }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                Task { await libraryVM.deleteSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除选中的 \(libraryVM.selectedIds.count) 本书籍，此操作不可恢复。")
        }
    }

    private var bookListColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("书目").font(.title3.bold())
                Spacer()
                if libraryVM.selectionMode {
                    Button("删除(\(libraryVM.selectedIds.count))") {
                        if !libraryVM.selectedIds.isEmpty { showDeleteConfirm = true }
                    }
                    .disabled(libraryVM.selectedIds.isEmpty)
                    Button("取消") { libraryVM.toggleSelectionMode() }
                } else {
                    Menu {
                        Button("从本地选择…") { pickFiles() }
                        Button("从 URL 导入…") { showUrlSheet = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("上传电子书")

                    Menu {
                        Button("\(sortLabel(.uploadTime, .desc))") { libraryVM.setSort(.uploadTime, .desc) }
                        Button("\(sortLabel(.uploadTime, .asc))") { libraryVM.setSort(.uploadTime, .asc) }
                        Button("\(sortLabel(.lastPlayed, .desc))") { libraryVM.setSort(.lastPlayed, .desc) }
                        Button("\(sortLabel(.lastPlayed, .asc))") { libraryVM.setSort(.lastPlayed, .asc) }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button {
                        libraryVM.toggleSelectionMode()
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .buttonStyle(.borderless)
                    .help("多选删除")
                }
            }
            .padding(12)
            Divider()

            if libraryVM.books.isEmpty {
                Spacer()
                Text("暂无书籍，点击右上角 + 上传")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(libraryVM.books) { book in
                            BookRow(
                                book: book,
                                selectionMode: libraryVM.selectionMode,
                                selected: libraryVM.selectedIds.contains(book.id),
                                isCurrent: selectedBookId == book.id,
                                onTap: {
                                    if libraryVM.selectionMode {
                                        libraryVM.toggleSelection(book.id)
                                    } else {
                                        selectedBookId = book.id
                                    }
                                },
                                onDelete: { Task { await libraryVM.deleteBook(book.id) } },
                                onRetry: { Task { await libraryVM.retryImport(book.id) } }
                            )
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func sortLabel(_ by: SortBy, _ order: SortOrder) -> String {
        let byLabel = by == .uploadTime ? "按上传时间" : "按最近播放"
        let orderLabel = order == .asc ? "正序" : "倒序"
        return "\(byLabel) · \(orderLabel)"
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择电子书"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.allowedFileTypes = ["epub"]
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await libraryVM.importLocalFiles(urls) }
        }
    }

    private var urlSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("从 URL 导入电子书").font(.headline)
            TextField("输入 EPUB 直链地址（http/https，URL 需含 .epub 扩展名）", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
            HStack {
                Spacer()
                Button("取消") { showUrlSheet = false }
                Button("开始导入") {
                    let url = urlInput
                    showUrlSheet = false
                    urlInput = ""
                    Task { await libraryVM.importFromUrl(url) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct BookRow: View {
    let book: BookWithProgress
    let selectionMode: Bool
    let selected: Bool
    let isCurrent: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if selectionMode {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            CoverImage(coverPath: book.coverPath)
                .frame(width: 44, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.headline).lineLimit(1)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                statusView
            }
            Spacer()
            if !selectionMode {
                if book.statusEnum == .failed {
                    Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("重试导入")
                }
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("删除")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isCurrent && !selectionMode ? Color.accentColor.opacity(0.12) : Color.clear)
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var statusView: some View {
        switch book.statusEnum {
        case .pending, .processing:
            ProgressView(value: Double(book.importProgress), total: 100)
                .controlSize(.small)
            Text(importStageLabel(progress: book.importProgress, sourceUrl: book.sourceUrl))
                .font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Text(book.importError ?? "导入失败")
                .font(.caption2).foregroundStyle(.red).lineLimit(2)
        case .completed:
            if book.sentenceCount > 0 {
                let progress = book.currentSentenceIndex ?? 0
                ProgressView(value: Double(progress), total: Double(max(book.sentenceCount, 1)))
                    .controlSize(.small)
                Text("\(progress) / \(book.sentenceCount) \(ProgressFormat.percentSuffix(progress, book.sentenceCount))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(book.lastPlayedTime.map { "最近播放 \(Formatters.dateTime($0))" } ?? "未播放")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func importStageLabel(progress: Int, sourceUrl: String?) -> String {
        let isUrl = !(sourceUrl ?? "").isEmpty
        if isUrl && progress < 5 { return "下载中" }
        if progress < 50 { return "解析中" }
        if progress < 75 { return "分句中" }
        return "建立索引"
    }
}
