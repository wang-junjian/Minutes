import SwiftUI

/// 历史会议的纪要视图。
struct MinutesView: View {
    let meeting: Meeting

    @Environment(MeetingsStore.self) private var store
    @Environment(EngineSupervisor.self) private var supervisor
    @State private var isRegenerating = false
    @State private var progressText = ""
    @State private var regenerationError: String?
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var isTitleEditorFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let regenerationError {
                    Text(regenerationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if isRegenerating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(progressText.isEmpty ? "正在生成纪要…" : progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let minutes = meeting.minutes {
                    structuredSections(minutes)
                }
                transcriptSection
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(meeting.title)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    regenerate()
                } label: {
                    Label("重新生成", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isRegenerating || meeting.segments.isEmpty || supervisor.states[.llm] != .ready)
                .help("使用当前提示词设置重新生成纪要")
            }
        }
    }

    /// 用于生成/重生成的转写全文。
    private var transcript: String {
        meeting.transcriptText.isEmpty
            ? meeting.segments.map(\.text).joined(separator: "\n")
            : meeting.transcriptText
    }

    private func regenerate() {
        let prompt = supervisor.configuration.minutesPrompt
        let baseURL = supervisor.configuration.baseURL(for: .llm)
        Task {
            isRegenerating = true
            progressText = ""
            regenerationError = nil
            defer { isRegenerating = false }
            let document: MinutesDocument
            do {
                document = try await MinutesComposer.generate(
                    segments: meeting.segments, prompt: prompt, baseURL: baseURL,
                    onProgress: { self.progressText = Self.progressText(for: $0) }
                )
            } catch is CancellationError {
                regenerationError = "重新生成已取消。"
                return
            } catch {
                regenerationError = "重新生成失败：\(error.localizedDescription)"
                return
            }
            var updated = meeting
            updated.minutes = document
            do {
                try store.save(updated)
            } catch {
                Log.error("保存重新生成的纪要失败：\(error.localizedDescription)")
            }
        }
    }

    private static func progressText(for stage: MinutesComposer.Stage) -> String {
        switch stage {
        case .generating:
            return "正在生成纪要…"
        case .mapping(let index, let total):
            return "正在整理第 \(index)/\(total) 段…"
        case .reducing:
            return "正在汇总纪要…"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditingTitle {
                TextField("会议标题", text: $titleDraft)
                    .font(.title).bold()
                    .textFieldStyle(.plain)
                    .focused($isTitleEditorFocused)
                    .onSubmit(saveTitle)
                    .onExitCommand {
                        isEditingTitle = false
                    }
                    .onChange(of: isTitleEditorFocused) { _, isFocused in
                        if !isFocused { saveTitle() }
                    }
                    .onAppear {
                        isTitleEditorFocused = true
                    }
            } else {
                Text(meeting.title)
                    .font(.title).bold()
                    .onTapGesture(count: 2) {
                        titleDraft = meeting.title
                        isEditingTitle = true
                    }
                    .help("双击编辑会议标题")
            }
            Text("\(dateText) · 时长 \(Formatters.clock(meeting.duration)) · \(meeting.segments.count) 条转写")
                .foregroundStyle(.secondary)
        }
    }

    private func saveTitle() {
        guard isEditingTitle else { return }
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != meeting.title {
            var updated = meeting
            updated.title = title
            do {
                try store.save(updated)
            } catch {
                Log.error("保存会议标题失败：\(error.localizedDescription)")
            }
        }
        isEditingTitle = false
    }

    /// 缓存的格式化器：DateFormatter 每次创建要几毫秒，不用反复建。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    private var dateText: String {
        Self.dateFormatter.string(from: meeting.createdAt)
    }

    @ViewBuilder
    private func structuredSections(_ minutes: MinutesDocument) -> some View {
        if !minutes.summary.isEmpty {
            section(title: "摘要", systemImage: "doc.text") {
                Text(minutes.summary)
            }
        }
        if !minutes.decisions.isEmpty {
            section(title: "决议", systemImage: "checkmark.circle") {
                bulletList(minutes.decisions)
            }
        }
        if !minutes.actionItems.isEmpty {
            section(title: "行动项", systemImage: "flag") {
                bulletList(minutes.actionItems)
            }
        }
        if !minutes.keywords.isEmpty {
            section(title: "关键词", systemImage: "tag") {
                FlowLayout(spacing: 8) {
                    ForEach(minutes.keywords, id: \.self) { keyword in
                        Text(keyword)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    private var transcriptSection: some View {
        section(title: "转写原文", systemImage: "waveform") {
            // 单个超长 Text 会在选中会议时同步排版全文，快速切换会阻塞主线程。
            // 按原有换行拆成懒加载行，只排版可见内容，同时保留逐行选择。
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(transcript.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func section<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.title3).bold()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.secondary)
                    Text(item)
                }
            }
        }
    }
}

/// 简单流式布局，用于关键词标签。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, position) in layout(proposal: proposal, subviews: subviews).positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: min(x, maxWidth), height: y + rowHeight), positions)
    }
}
