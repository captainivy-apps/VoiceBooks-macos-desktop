import SwiftUI

struct SettingsScreen: View {
    let services: AppServices
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var libraryVM: LibraryViewModel

    @State private var tab: SettingsTab = .general

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "通用"
        case tts = "TTS 引擎管理"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("设置").font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .general: generalTab
                    case .tts: ttsTab
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(16)
            }

            if viewModel.hasPendingChanges {
                Divider()
                HStack {
                    Text("有未应用的引擎更改").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消更改") { viewModel.discardChanges() }
                    Button("确认应用") {
                        Task { await viewModel.applyPending() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.applying)
                }
                .padding(12)
                .background(.bar)
            }
        }
        .task { await viewModel.refresh() }
        .overlay {
            if viewModel.applying {
                ZStack {
                    Color.black.opacity(0.15)
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在加载引擎，请稍候…").foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("播放时保持屏幕常亮", isOn: Binding(
                get: { viewModel.keepScreenOn },
                set: { viewModel.setKeepScreenOn($0) }
            ))

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("重建书库").font(.title3.bold())
                Text("删除重复检测索引和电子书元信息后，重新扫描书库并完整重建。耗时较长。")
                    .font(.caption).foregroundStyle(.secondary)
                if libraryVM.isRebuilding {
                    ProgressView(value: Double(libraryVM.rebuildProgress.processedFiles),
                                 total: Double(max(libraryVM.rebuildProgress.totalFiles, 1)))
                    Text("进度：\(libraryVM.rebuildProgress.processedFiles) / \(libraryVM.rebuildProgress.totalFiles)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let name = libraryVM.rebuildProgress.currentFileName {
                        Text("当前文件：\(name)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Button("重建书库") { Task { await libraryVM.rebuildLibrary() } }
                }
            }
        }
    }

    private var ttsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择「选为默认」后点击底部「确认应用」以加载并切换离线引擎。")
                .font(.caption).foregroundStyle(.secondary)

            Picker("语言", selection: Binding(
                get: { viewModel.languageFilter ?? "all" },
                set: { viewModel.selectLanguageFilter($0 == "all" ? nil : $0) }
            )) {
                Text(TtsLanguageGroups.allLabel).tag("all")
                ForEach(viewModel.distinctGroups, id: \.id) { group in
                    Text(group.label).tag(group.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240, alignment: .leading)

            ForEach(viewModel.filteredGroups, id: \.group.id) { entry in
                Text(entry.group.label).font(.title3.bold()).padding(.top, 6)
                ForEach(entry.models, id: \.id) { model in
                    TtsModelCard(services: services, viewModel: viewModel, model: model)
                }
            }
        }
    }
}

private struct TtsModelCard: View {
    let services: AppServices
    @ObservedObject var viewModel: SettingsViewModel
    let model: TtsModelEntity

    private var isDownloaded: Bool { model.downloadState == TtsDownloadState.downloaded.rawValue }
    private var isSelectedDefault: Bool { viewModel.pendingDefaultModelId == model.id }
    private var showPendingApply: Bool { viewModel.showPendingApply(for: model.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name).font(.headline)
                        if model.isDefault && !showPendingApply {
                            Text("默认").font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                        if showPendingApply {
                            Text("待应用").font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.22), in: Capsule())
                        }
                    }
                    Text("\(Formatters.fileSize(model.sizeBytes)) · \(stateText)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if isDownloaded {
                HStack(spacing: 10) {
                    Button {
                        viewModel.selectModel(model.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isSelectedDefault ? "largecircle.fill.circle" : "circle")
                            Text("选为默认")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.applying)

                    Spacer()

                    Button(viewModel.previewingModelId == model.id ? "停止" : "试听") {
                        Task { await viewModel.preview(model.id) }
                    }
                    .disabled(viewModel.applying)

                    Button("删除") {
                        Task { await viewModel.deleteModel(model.id) }
                    }
                    .disabled(viewModel.applying)
                }
            } else {
                actions
            }

            if isDownloaded {
                speakerControls
            }

            if let progress = viewModel.downloadProgress[model.id] {
                ProgressView(value: Double(progress), total: 1.0)
                Text("下载中… \(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var stateText: String {
        switch model.stateEnum {
        case .notDownloaded: return "未下载"
        case .downloading: return "下载中"
        case .downloaded: return "已下载"
        case .failed: return model.downloadError ?? "下载失败"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.stateEnum {
        case .notDownloaded, .failed:
            HStack {
                Button("下载") { Task { await viewModel.downloadModel(model.id, useMirror: false) } }
                if BuiltInTtsModels.info(for: model.id)?.mirrorDownloadUrl != nil {
                    Button("镜像下载") { Task { await viewModel.downloadModel(model.id, useMirror: true) } }
                }
            }
            .disabled(viewModel.applying)
        case .downloading:
            ProgressView().controlSize(.small)
        case .downloaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var speakerControls: some View {
        let count = viewModel.maxSpeakerCount(for: model.id)
        if count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                Text("音色").font(.caption).foregroundStyle(.secondary)
                if count <= 10 {
                    Picker("音色", selection: Binding(
                        get: { viewModel.speakerId(for: model.id) },
                        set: { viewModel.updateSpeaker(modelId: model.id, speakerId: $0) }
                    )) {
                        ForEach(0..<count, id: \.self) { id in
                            Text("音色 \(id)").tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 160, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        TextField("音色编号 (0–\(count - 1))", value: Binding(
                            get: { viewModel.speakerId(for: model.id) },
                            set: { viewModel.updateSpeaker(modelId: model.id, speakerId: $0) }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    }
                }
                if let benchmark = viewModel.benchmark(for: model.id, speakerId: viewModel.speakerId(for: model.id)) {
                    Text(String(format: "RTF %.2f · %dkHz", benchmark.rtf, benchmark.sampleRate / 1000))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
