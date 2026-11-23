import SwiftUI

/// 中断会议恢复面板：启动时检测到草稿快照（ADR-0002）则出现。
/// 继续录制恢复到暂停态，由用户在实时视图显式开麦；稍后处理保留草稿，
/// 下次启动再提示。
struct RecoveryView: View {
    let drafts: [MeetingDraft]
    let errorMessage: String?
    let onResume: (MeetingDraft) -> Void
    let onFinish: (MeetingDraft) -> Void
    let onDiscard: (MeetingDraft) -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("检测到中断的会议")
                .font(.title2)
                .bold()
            Text("这些会议尚未完成，音频与转写已自动保存。选择如何继续：")
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(drafts, id: \.meeting.id) { draft in
                VStack(alignment: .leading, spacing: 8) {
                    Text(draft.meeting.title.isEmpty ? "未命名会议" : draft.meeting.title)
                        .font(.headline)
                    Text("\(Self.dateFormatter.string(from: draft.meeting.createdAt)) · 已保存 \(Formatters.clock(draft.meeting.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("继续录制") { onResume(draft) }
                            .buttonStyle(.borderedProminent)
                        Button("结束并生成纪要") { onFinish(draft) }
                        Button("放弃") { onDiscard(draft) }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Spacer()
                Button("稍后处理", action: onLater)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}
