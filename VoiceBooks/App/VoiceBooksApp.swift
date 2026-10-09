import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var services: AppServices?

    func applicationWillTerminate(_ notification: Notification) {
        // Quiesce all native Sherpa/onnxruntime work before `exit()` finalizes
        // the C++ globals, otherwise the dedicated TTS thread races teardown
        // and the app crashes (reported as "quit unexpectedly").
        services?.shutdown()
    }
}

@main
struct VoiceBooksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
                .frame(minWidth: 1000, minHeight: 680)
                .task {
                    appDelegate.services = services
                    services.start()
                }
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
