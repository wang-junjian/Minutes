import SwiftUI

struct SidebarView: View {
    @Environment(MeetingsStore.self) private var store
    @Binding var selection: Meeting.ID?
    @State private var pendingDeletion: Meeting?
    @State private var hoveredID: Meeting.ID?

    var body: some View {
        List(selection: $selection) {
            Section("会议") {
                ForEach(store.meetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title.isEmpty ? "未命名会议" : meeting.title)
                                    .lineLimit(1)
                                Text(subtitle(for: meeting))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button {
                                pendingDeletion = meeting
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.body)
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("删除会议")
                            // 常驻占位避免显隐时布局跳动，仅透明度变化
                            .frame(width: 18)
                            .opacity(hoveredID == meeting.id ? 1 : 0)
                        }
                    }
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            hoveredID = hovering ? meeting.id : nil
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet { store.delete(store.meetings[index]) }
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
        .confirmationDialog(
            "删除「\(pendingDeletion?.title.isEmpty == false ? pendingDeletion!.title : "未命名会议")」？转写与纪要将一并删除，不可恢复。",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let meeting = pendingDeletion {
                    if selection == meeting.id { selection = nil }
                    store.delete(meeting)
                }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
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
