import SwiftUI

struct BookDetailColumn: View {
    let services: AppServices
    let bookId: String?
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject private var playback = PlaybackController.shared

    var body: some View {
        Group {
            if let bookId {
                if playback.state.bookId == bookId, isActiveSession {
                    PlayerView(services: services, bookId: bookId)
                } else {
                    BookDetailView(services: services, bookId: bookId, libraryVM: libraryVM)
                        .id(bookId)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "book")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("选择左侧书籍查看详情")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var isActiveSession: Bool {
        switch playback.state.playbackState {
        case .loading, .playing, .paused, .error: return true
        default: return false
        }
    }
}

struct BookDetailView: View {
    let services: AppServices
    let bookId: String
    @ObservedObject var libraryVM: LibraryViewModel

    @State private var book: BookEntity?
    @State private var refreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    CoverImage(coverPath: book?.coverPath)
                        .frame(width: 150, height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(radius: 4)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(book?.title ?? "").font(.title2.bold())
                        Text((book?.author.isEmpty == false) ? (book?.author ?? "") : "未知作者")
                            .foregroundStyle(.secondary)
                        if let summary = book?.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                        }
                        Spacer(minLength: 0)
                        Button {
                            services.playbackEngine.play(bookId: bookId)
                        } label: {
                            Label("开始播放", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(book?.importStatus != .completed)
                    }
                }

                if let book {
                    Divider()
                    metadataGrid(book)
                    Divider()
                    HStack {
                        Button {
                            Task { await refreshMetadata() }
                        } label: {
                            Label("刷新元数据", systemImage: "arrow.clockwise")
                        }
                        .disabled(refreshing)
                        Button {
                            copyBookInfo(book)
                        } label: {
                            Label("复制书籍信息", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .task(id: bookId) { await load() }
    }

    private func metadataGrid(_ book: BookEntity) -> some View {
        let rows: [(String, String)] = [
            ("出版社", book.publisher ?? ""),
            ("出版时间", book.publishedDate ?? ""),
            ("语言", book.language ?? ""),
            ("ISBN", book.isbn ?? ""),
            ("分类", book.subjects ?? ""),
            ("格式", book.format.displayName),
            ("句数", "共 \(book.sentenceCount) 句"),
            ("上传时间", Formatters.dateTime(book.uploadTime)),
            ("来源链接", book.sourceUrl ?? ""),
        ].filter { !$0.1.isEmpty }

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top, spacing: 12) {
                    Text(row.0).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Text(row.1).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func load() async {
        book = try? await services.bookRepository.getBook(bookId)
    }

    private func refreshMetadata() async {
        refreshing = true
        defer { refreshing = false }
        do {
            book = try await services.bookRepository.refreshBookMetadata(bookId: bookId)
            AppNotifier.shared.show("书籍信息已更新")
            await libraryVM.refresh()
        } catch {
            AppNotifier.shared.show(ImportErrorMessages.toUserMessage(error), long: true)
        }
    }

    private func copyBookInfo(_ book: BookEntity) {
        var lines: [String] = []
        lines.append("书名：\(book.title)")
        lines.append("作者：\(book.author)")
        if let publisher = book.publisher, !publisher.isEmpty { lines.append("出版社：\(publisher)") }
        if let date = book.publishedDate, !date.isEmpty { lines.append("出版时间：\(date)") }
        if let language = book.language, !language.isEmpty { lines.append("语言：\(language)") }
        if let isbn = book.isbn, !isbn.isEmpty { lines.append("ISBN：\(isbn)") }
        if let subjects = book.subjects, !subjects.isEmpty { lines.append("分类：\(subjects)") }
        if !book.summary.isEmpty { lines.append("摘要：\(book.summary)") }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        AppNotifier.shared.show("已复制到剪贴板")
    }
}
