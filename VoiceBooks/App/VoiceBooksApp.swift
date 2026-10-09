import SwiftUI

@main
struct VoiceBooksApp: App {
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
                .frame(minWidth: 1000, minHeight: 680)
                .task { services.start() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("播放") {
                Button("播放/暂停") {
                    services.playbackEngine.toggle(bookId: nil)
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("快退 10 句") { services.playbackEngine.rewind() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("快进 10 句") { services.playbackEngine.forward() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
        }
    }
}
