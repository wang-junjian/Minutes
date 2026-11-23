import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(MeetingsStore.self) private var store
    @Binding var selection: Meeting.ID?
    @State private var deletionConfirmation = MeetingDeletionConfirmation()
    @State private var hoveredID: Meeting.ID?
    @FocusState private var focusedDeletionID: Meeting.ID?

    var body: some View {
        List(selection: $selection) {
            Section("会议") {
                ForEach(store.meetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        rowContent(for: meeting)
                    }
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            hoveredID = hovering ? meeting.id : nil
                        }
                    }
                }
                .onDelete { indexSet in
                    let targets = indexSet.map { store.meetings[$0].id }
                    requestDeletion(targets: targets, focusConfirmation: true)
                }
            }
        }
        .overlay {
            if store.meetings.isEmpty {
                // 不用 ContentUnavailableView：窄栏里它的大标题会换行得非常难看。
                VStack(spacing: 6) {
                    Image(systemName: "mic.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无会议")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
                .padding(.bottom, 40)
            }
        }
        .onChange(of: selection) { _, newSelection in
            guard let pending = deletionConfirmation.pendingMeetingID,
                  pending != newSelection else { return }
            cancelDeletion()
        }
        .onChange(of: store.meetings.map(\.id)) { _, meetingIDs in
            guard let pending = deletionConfirmation.pendingMeetingID,
                  !meetingIDs.contains(pending) else { return }
            cancelDeletion()
        }
        .onExitCommand { cancelDeletion() }
        .onDisappear { cancelDeletion() }
        .task(id: deletionConfirmation.armedAt) {
            guard let armedAt = deletionConfirmation.armedAt else { return }
            let remaining = max(0, MeetingDeletionConfirmation.confirmationWindow - (now - armedAt))
            if remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            deletionConfirmation.cancelIfExpired(at: now)
        }
    }

    private func rowContent(for meeting: Meeting) -> some View {
        let isPending = deletionConfirmation.pendingMeetingID == meeting.id
        let isDeleteControlVisible = isPending || hoveredID == meeting.id
        let title = meeting.title.isEmpty ? "未命名会议" : meeting.title

        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                if isPending {
                    Text("永久删除，不可恢复")
                        .lineLimit(1)
                    Text("含转写、纪要、音频及草稿")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(title)
                        .lineLimit(1)
                    Text(subtitle(for: meeting))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(-1)
            Spacer(minLength: 0)
            Button {
                if isPending {
                    confirmDeletion(meeting)
                } else {
                    requestDeletion(targets: [meeting.id], focusConfirmation: false)
                }
            } label: {
                if isPending {
                    Text("确认删除")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(Color.red))
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isPending ? Color.white : Color.secondary)
            .help(isPending
                ? "将永久删除「\(title)」及其转写、纪要、音频和草稿，不可恢复。点击其他位置或按 Esc 取消。"
                : "删除会议")
            .frame(width: isPending ? nil : 18, height: 18)
            .background {
                if isPending {
                    DeletionCancellationBridge(onCancel: cancelDeletion)
                }
            }
            .opacity(isDeleteControlVisible ? 1 : 0)
            .allowsHitTesting(isDeleteControlVisible)
            .focusable(isDeleteControlVisible)
            .focused($focusedDeletionID, equals: meeting.id)
            .accessibilityLabel(isPending ? "确认删除「\(title)」" : "删除会议「\(title)」")
            .accessibilityHint(isPending
                ? "转写、纪要、音频和草稿将一并永久删除，不可恢复。按 Escape 取消。"
                : "")
        }
    }

    private func requestDeletion(targets: [Meeting.ID], focusConfirmation: Bool) {
        switch deletionConfirmation.arm(targets: targets, at: now) {
        case .armed:
            guard focusConfirmation, let target = deletionConfirmation.pendingMeetingID else { return }
            selection = target
            // 等 SwiftUI 完成可见性与 focusable 更新后再移动焦点。
            DispatchQueue.main.async {
                guard deletionConfirmation.pendingMeetingID == target else { return }
                focusedDeletionID = target
            }
        case .rejectedBatch:
            store.rejectBatchDeletion()
        }
    }

    private func confirmDeletion(_ meeting: Meeting) {
        guard deletionConfirmation.confirm(meetingID: meeting.id, at: now) else { return }
        focusedDeletionID = nil
        delete(meeting)
    }

    private func cancelDeletion() {
        deletionConfirmation.cancel()
        focusedDeletionID = nil
    }

    private var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func delete(_ meeting: Meeting) {
        do {
            try store.delete(meeting)
            if selection == meeting.id { selection = nil }
        } catch {
            Log.error("删除会议失败：\(error.localizedDescription)")
        }
    }

    /// 复用的日期格式化器。DateFormatter 创建极贵（.locale 查找每次数毫秒），
    /// 侧栏每行每个渲染周期都新建一次的话，快速切换会议会明显卡顿。
    private static let subtitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private func subtitle(for meeting: Meeting) -> String {
        "\(Self.subtitleFormatter.string(from: meeting.createdAt)) · \(Formatters.clock(meeting.duration))"
    }
}

/// 仅在待确认按钮背后挂载：本机点击落在按钮外时取消，窗口失焦时也取消。
/// 坐标检查保证点击确认按钮本身不会被监听器抢先取消。
private struct DeletionCancellationBridge: NSViewRepresentable {
    let onCancel: () -> Void

    func makeNSView(context: Context) -> DeletionCancellationView {
        let view = DeletionCancellationView()
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: DeletionCancellationView, context: Context) {
        view.onCancel = onCancel
    }

    static func dismantleNSView(_ view: DeletionCancellationView, coordinator: ()) {
        view.stopMonitoring()
    }
}

@MainActor
private final class DeletionCancellationView: NSView {
    var onCancel: (() -> Void)?
    private var eventMonitor: Any?
    private var windowObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard event.window === self.window else {
                    self.onCancel?()
                    return
                }
                let location = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(location) {
                    self.onCancel?()
                }
            }
            return event
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onCancel?()
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
    }
}
