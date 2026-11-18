import SwiftUI
import AppKit

@main
struct MinutesApp: App {
    @State private var store = MeetingsStore.shared
    @State private var supervisor = EngineSupervisor.shared
    @State private var session: MeetingSession?

    /// macOS 14+ 原生打开「设置」场景的 action；旧的 showSettingsWindow:
    /// 选择器调法在新系统上无响应（设置按钮点了不弹窗的根因）。
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        WindowGroup {
            ContentView(session: $session)
                .environment(store)
                .environment(supervisor)
                .frame(minWidth: 760, minHeight: 520)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    supervisor.stopAll()
                }
        }
        .defaultSize(width: 980, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("引擎设置…") {
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(supervisor)
        }
    }
}
