import SwiftUI
import AppKit

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .navigationTitle("引擎设置")
                .environment(supervisor)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单元测试只加载目标组件，避免测试宿主启动真实模型进程。
        guard NSClassFromString("XCTestCase") == nil else { return }
        EngineSupervisor.shared.startAll()

        // 重启应用时，上一实例的模型进程可能仍在退出。短暂等待后只重试
        // 启动失败的 worker；持续被外部服务占用时仍会明确显示失败。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            let supervisor = EngineSupervisor.shared
            for kind in EngineWorkerKind.allCases {
                if case .failed = supervisor.states[kind] {
                    supervisor.start(kind)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EngineSupervisor.shared.stopAll()
    }
}
