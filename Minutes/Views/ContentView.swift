import SwiftUI

/// 应用主框架：左侧会议列表，右侧详情；正在进行时固定显示实时视图。
struct ContentView: View {
    @Environment(MeetingsStore.self) private var store
    @Environment(EngineSupervisor.self) private var supervisor
    @Environment(\.openSettings) private var openSettings
    @Binding var session: MeetingSession?

    @State private var selection: Meeting.ID?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            if let session, session.phase != .idle, session.phase != .completed {
                LiveMeetingView(session: session)
            } else if let selected = store.meetings.first(where: { $0.id == selection }) {
                MinutesView(meeting: selected)
            } else {
                emptyState
            }
        }
        .onChange(of: session?.phase) { _, newPhase in
            // 结束后回到纪要页：选中刚保存的会议并释放会话。
            if newPhase == .completed, let session {
                selection = session.meeting.id
                self.session = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewMeeting()
                } label: {
                    Label("新会议", systemImage: "record.circle")
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    openSettings()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .keyboardShortcut(",")
            }
        }
        .onAppear {
            // 单元测试只加载目标组件，避免测试宿主启动真实模型进程。
            if NSClassFromString("XCTestCase") == nil {
                supervisor.startAll()
            }
        }
    }

    /// 无选中时的主空状态：一个明确的主按钮，而不是让人找工具栏。
    /// 不用 ContentUnavailableView 的 actions 形式——macOS 14 上它在部分
    /// SwiftUI 版本里有已知的按钮分发崩溃。
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Minutes")
                .font(.title)
                .bold()
            Text("点击「开始新会议」，全程本地转写并自动生成纪要。\n音频与文本不出本机。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("开始新会议") {
                startNewMeeting()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startNewMeeting() {
        let newSession = MeetingSession(store: store)
        session = newSession
        selection = nil
        newSession.start()
    }
}
