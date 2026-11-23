import SwiftUI

/// 应用主框架：左侧会议列表，右侧详情；正在进行时固定显示实时视图。
struct ContentView: View {
    @Environment(MeetingsStore.self) private var store
    @Environment(EngineSupervisor.self) private var supervisor
    @Environment(\.openSettings) private var openSettings
    @Binding var session: MeetingSession?
    let appDelegate: AppDelegate

    @State private var selection: Meeting.ID?
    @State private var interrupted: [MeetingDraft] = []
    @State private var recoveryDismissed = false
    @State private var recoveryError: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                }
                if let session, session.phase != .idle, session.phase != .completed {
                    LiveMeetingView(session: session)
                } else if let selected = store.meetings.first(where: { $0.id == selection }) {
                    MinutesView(meeting: selected)
                } else {
                    emptyState
                }
            }
        }
        .onChange(of: session?.phase) { _, newPhase in
            // 结束后回到纪要页：选中刚保存的会议并释放会话。
            if newPhase == .completed, let session {
                selection = session.meeting.id
                self.session = nil
                // 多场中断逐个处理：一场完成后，其余中断会议再次提示。
                if !interrupted.isEmpty { recoveryDismissed = false }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                EngineStatusControl()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewMeeting()
                } label: {
                    Label("新会议", systemImage: "record.circle")
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!canStartNewMeeting)
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
        .background(WindowLifecycleBridge(appDelegate: appDelegate))
        .onAppear {
            appDelegate.session = session
            // 草稿快照存在即中断信号（ADR-0002）；历史列表只含已完成会议。
            let drafts = MeetingDraftStore(directory: store.directory)
            let all = drafts.loadAll()
            // 自愈：已完成会议的同名残留草稿（完成清理曾失败）不提示中断，直接清理。
            interrupted = all.filter { draft in
                let completed = store.meetings.contains { $0.id == draft.meeting.id }
                if completed { drafts.delete(id: draft.meeting.id) }
                return !completed
            }
            // 启动即确定性修复 WAV 头部，稍后处理或恢复时音频均已可读。
            for draft in interrupted {
                try? MeetingAudioFile.repair(at: store.audioURL(for: draft.meeting))
            }
        }
        .sheet(isPresented: Binding(
            get: { !interrupted.isEmpty && !recoveryDismissed && session == nil },
            set: { if !$0 { recoveryDismissed = true } }
        )) {
            RecoveryView(
                drafts: interrupted,
                errorMessage: recoveryError,
                onResume: { draft in restoreInterrupted(draft, finish: false) },
                onFinish: { draft in restoreInterrupted(draft, finish: true) },
                onDiscard: discardInterrupted,
                onLater: { recoveryDismissed = true }
            )
        }
        .onChange(of: session.map { ObjectIdentifier($0) }) { _, _ in
            appDelegate.session = session
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
            Text("纪要")
                .font(.title)
                .bold()
            Text("全程本地转写并自动生成会议纪要，音频与文本不出本机。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if supervisor.states[.asr] != .ready {
                Text(startupHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("开始新会议") {
                startNewMeeting()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(supervisor.states[.asr] != .ready)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startupHint: String {
        switch supervisor.states[.asr] ?? .stopped {
        case .failed(let message):
            return "语音识别模型启动失败：\(message)\n可点击工具栏的模型状态重新启动。"
        case .stopped:
            return "语音识别模型已停止，可点击工具栏的模型状态重新启动。"
        case .starting:
            return "模型正在启动，语音识别就绪后即可开始会议。"
        case .ready:
            return ""
        }
    }

    private var canStartNewMeeting: Bool {
        guard supervisor.states[.asr] == .ready else { return false }
        guard let session else { return true }
        return session.phase == .idle || session.phase == .completed
    }

    private func startNewMeeting() {
        guard canStartNewMeeting else { return }
        let newSession = MeetingSession(store: store)
        session = newSession
        selection = nil
        newSession.start()
    }

    /// 恢复中断会议：暂停态进入实时视图；选择结束时直接走结束事务。
    private func restoreInterrupted(_ draft: MeetingDraft, finish: Bool) {
        do {
            let restored = try MeetingSession(restoring: draft, store: store)
            session = restored
            interrupted.removeAll { $0.meeting.id == draft.meeting.id }
            recoveryDismissed = true
            recoveryError = nil
            if finish {
                Task { await restored.finish() }
            }
        } catch {
            recoveryError = "恢复会议失败：\(error.localizedDescription)"
        }
    }

    /// 放弃中断会议：级联删除草稿与音频，清理失败明确提示。
    private func discardInterrupted(_ draft: MeetingDraft) {
        MeetingDraftStore(directory: store.directory).delete(id: draft.meeting.id)
        let audioURL = store.audioURL(for: draft.meeting)
        if FileManager.default.fileExists(atPath: audioURL.path) {
            do {
                try FileManager.default.removeItem(at: audioURL)
            } catch {
                recoveryError = "音频清理失败：\(error.localizedDescription)"
            }
        }
        interrupted.removeAll { $0.meeting.id == draft.meeting.id }
    }
}
