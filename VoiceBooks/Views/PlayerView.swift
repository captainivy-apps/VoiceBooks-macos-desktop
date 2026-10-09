import SwiftUI

struct PlayerView: View {
    let services: AppServices
    let bookId: String

    @ObservedObject private var playback = PlaybackController.shared
    @State private var page: PlayerPage = .cover
    @State private var customSleepMinutes = 30
    @State private var showCustomSleep = false

    private enum PlayerPage: String, CaseIterable, Identifiable {
        case cover = "封面"
        case subtitle = "字幕"
        case info = "书籍信息"
        var id: String { rawValue }
    }

    private var state: PlaybackUiState { playback.state }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $page) {
                ForEach(PlayerPage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ZStack {
                pageContent
                if state.playbackState == .loading, state.loadingStage != .none {
                    loadingOverlay
                }
                if state.playbackState == .error {
                    errorOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            controls
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.bookTitle.isEmpty ? "正在播放" : state.bookTitle)
                    .font(.headline).lineLimit(1)
                Text(state.bookAuthor.isEmpty ? "未知作者" : state.bookAuthor)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("停止") { services.playbackEngine.stop() }
        }
        .padding(12)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .cover:
            VStack {
                Spacer()
                CoverImage(coverPath: state.coverPath)
                    .frame(width: 220, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 8)
                Spacer()
            }
        case .subtitle:
            ScrollView {
                Text(state.currentSentenceText)
                    .font(.title3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .textSelection(.enabled)
            }
        case .info:
            BookInfoPage(services: services, bookId: bookId)
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(loadingStageText(state.loadingStage))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var errorOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
            Text(state.lastError ?? "播放出现问题，请重试")
                .multilineTextAlignment(.center)
            Button("重试播放") { services.playbackEngine.play(bookId: bookId) }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(24)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if state.totalSentences > 0 {
                Text("\(state.currentSentenceIndex + 1) / \(state.totalSentences)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                Button {
                    services.playbackEngine.rewind()
                } label: {
                    Image(systemName: "gobackward.10").font(.title2)
                }
                .buttonStyle(.plain)

                Button {
                    services.playbackEngine.toggle(bookId: bookId)
                } label: {
                    Image(systemName: state.playbackState == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)

                Button {
                    services.playbackEngine.forward()
                } label: {
                    Image(systemName: "goforward.10").font(.title2)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 16) {
                speedMenu
                sleepMenu
            }
            if state.sleepTimerRemainingMs > 0 {
                Text("剩余 \(Formatters.clock(state.sleepTimerRemainingMs))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if state.sleepUntilEndOfBook {
                Text("播放完本书后停止")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 14)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0], id: \.self) { speed in
                Button(String(format: "%.2fx", speed)) {
                    services.playbackEngine.setSpeed(Float(speed))
                    AppSettings.playbackSpeed = Float(speed)
                }
            }
        } label: {
            Label(String(format: "%.2fx", state.speed), systemImage: "speedometer")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sleepMenu: some View {
        Menu {
            Button("关闭") { services.playbackEngine.setSleepTimer(endOfBook: false, minutes: 0) }
            Button("15 分钟") { services.playbackEngine.setSleepTimer(endOfBook: false, minutes: 15) }
            Button("30 分钟") { services.playbackEngine.setSleepTimer(endOfBook: false, minutes: 30) }
            Button("1 小时") { services.playbackEngine.setSleepTimer(endOfBook: false, minutes: 60) }
            Button("播放完本书") { services.playbackEngine.setSleepTimer(endOfBook: true, minutes: 0) }
            Divider()
            Button("自定义…") { showCustomSleep = true }
        } label: {
            Label("睡眠定时", systemImage: "moon.zzz")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(isPresented: $showCustomSleep) {
            VStack(spacing: 16) {
                Text("自定义睡眠定时").font(.headline)
                Stepper("\(customSleepMinutes) 分钟", value: $customSleepMinutes, in: 1...600)
                    .frame(width: 220)
                HStack {
                    Button("取消") { showCustomSleep = false }
                    Button("开始") {
                        services.playbackEngine.setSleepTimer(endOfBook: false, minutes: customSleepMinutes)
                        showCustomSleep = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
    }

    private func loadingStageText(_ stage: TtsLoadingStage) -> String {
        switch stage {
        case .loadingBook: return "正在加载书籍…"
        case .initEngine: return "正在初始化 TTS 引擎…"
        case .initSherpa: return "正在加载离线模型…"
        case .preloading: return "正在预加载语音…"
        case .readingText: return "正在读取当前段落…"
        case .synthesizing: return "正在合成语音…"
        case .preparingFirst: return "正在准备首句语音…"
        case .outputtingAudio: return "正在输出音频…"
        case .none: return ""
        }
    }
}

private struct BookInfoPage: View {
    let services: AppServices
    let bookId: String
    @State private var book: BookEntity?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let book {
                    row("书名", book.title)
                    row("作者", book.author)
                    if let publisher = book.publisher, !publisher.isEmpty { row("出版社", publisher) }
                    if let date = book.publishedDate, !date.isEmpty { row("出版时间", date) }
                    if let language = book.language, !language.isEmpty { row("语言", language) }
                    if let isbn = book.isbn, !isbn.isEmpty { row("ISBN", isbn) }
                    if let subjects = book.subjects, !subjects.isEmpty { row("分类", subjects) }
                    row("格式", book.format.displayName)
                    row("句数", "共 \(book.sentenceCount) 句")
                    if !book.summary.isEmpty {
                        Text("摘要").foregroundStyle(.secondary).padding(.top, 8)
                        Text(book.summary).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task(id: bookId) { book = try? await services.bookRepository.getBook(bookId) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
