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
            ContentView(session: $session, appDelegate: appDelegate)
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var mainWindow: NSWindow?
    var session: MeetingSession?
    private var isPresentingClosePrompt = false

    private var activeSession: MeetingSession? {
        guard let session, session.phase != .idle, session.phase != .completed else { return nil }
        return session
    }

    private func confirmDiscard(actionTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "会议尚未完成"
        alert.informativeText = "返回会议可以继续录制或结束；放弃后，未保存的转写与纪要不会保留。"
        alert.addButton(withTitle: "返回会议")
        alert.addButton(withTitle: actionTitle)
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单元测试只加载目标组件，避免测试宿主启动真实模型进程。
        guard NSClassFromString("XCTestCase") == nil else { return }
        EngineSupervisor.shared.startAllForApplicationLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = activeSession else { return .terminateNow }
        guard !isPresentingClosePrompt else { return .terminateLater }
        isPresentingClosePrompt = true
        guard confirmDiscard(actionTitle: "放弃并退出") else {
            isPresentingClosePrompt = false
            sender.reply(toApplicationShouldTerminate: false)
            return .terminateLater
        }
        Task { @MainActor in
            await session.discard()
            isPresentingClosePrompt = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session = activeSession else { return true }
        guard !isPresentingClosePrompt else { return false }
        isPresentingClosePrompt = true
        guard confirmDiscard(actionTitle: "放弃并关闭") else {
            isPresentingClosePrompt = false
            return false
        }
        Task { @MainActor in
            await session.discard()
            isPresentingClosePrompt = false
            sender.close()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        EngineSupervisor.shared.stopAll()
    }
}
