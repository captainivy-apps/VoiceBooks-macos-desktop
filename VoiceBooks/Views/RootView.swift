import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case library = "书库"
    case settings = "设置"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .library: return "books.vertical"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    let services: AppServices

    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var settingsVM: SettingsViewModel
    @State private var section: SidebarSection? = .library
    @State private var selectedBookId: String?
    @State private var showStartupAlert = false

    @ObservedObject private var playback = PlaybackController.shared
    @ObservedObject private var notifier = AppNotifier.shared

    init(services: AppServices) {
        self.services = services
        _libraryVM = StateObject(wrappedValue: LibraryViewModel(services: services))
        _settingsVM = StateObject(wrappedValue: SettingsViewModel(services: services))
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.systemImage).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch section ?? .library {
            case .library:
                LibraryScreen(services: services, libraryVM: libraryVM, selectedBookId: $selectedBookId)
            case .settings:
                SettingsScreen(services: services, viewModel: settingsVM, libraryVM: libraryVM)
            }
        }
        .task {
            await libraryVM.load()
            await settingsVM.refresh()
        }
        .overlay(alignment: .bottom) {
            ToastView(notification: notifier.current)
                .animation(.easeInOut(duration: 0.2), value: notifier.current)
        }
        .onChange(of: playback.state.bookId) { newValue in
            if !newValue.isEmpty, section == .library {
                selectedBookId = newValue
            }
        }
        .onChange(of: services.startupIssue?.isLibraryIssue) { isLibrary in
            if isLibrary == true { showStartupAlert = true }
        }
        .alert("检测到书库异常", isPresented: $showStartupAlert) {
            Button("去设置页重建书库") {
                section = .settings
                services.clearStartupIssue()
            }
            Button("取消", role: .cancel) { services.clearStartupIssue() }
        } message: {
            Text("启动时发现书库或索引异常。建议前往设置页重建书库以恢复正常使用。")
        }
    }
}
