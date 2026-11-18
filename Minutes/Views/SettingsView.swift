import SwiftUI
import AppKit

/// 设置：引擎路径、端口、worker 状态、诊断日志。
struct SettingsView: View {
    @Environment(EngineSupervisor.self) private var supervisor
    @Bindable private var configuration = EngineConfiguration.shared

    var body: some View {
        Form {
            Section("模型") {
                PathField(title: "语音识别模型（GGUF）", text: $configuration.asrModelPath)
                ValidationText(configuration.modelPathError(for: .asr))
                PathField(title: "语言模型（GGUF）", text: $configuration.llmModelPath)
                ValidationText(configuration.modelPathError(for: .llm))
            }

            Section("引擎") {
                PathField(title: "引擎目录", text: $configuration.engineRoot)
                HStack {
                    Text("端口")
                    Spacer()
                    ForEach(EngineWorkerKind.allCases) { kind in
                        LabeledContent(kind.rawValue.uppercased()) {
                            TextField("", value: portBinding(for: kind), format: .number)
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                LabeledContent("状态") {
                    HStack(spacing: 12) {
                        ForEach(EngineWorkerKind.allCases) { kind in
                            WorkerStatusPill(kind: kind, state: supervisor.states[kind] ?? .stopped)
                        }
                    }
                }
                HStack {
                    Button("全部启动") { supervisor.startAll() }
                    Button("全部停止", role: .destructive) { supervisor.stopAll() }
                        .disabled(supervisor.allReady == false && supervisor.states.values.allSatisfy { $0 == .stopped })
                }
            }

            Section("纪要生成") {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $configuration.minutesPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 150)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    HStack {
                        Text("修改后在纪要页点「重新生成」生效")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") { configuration.minutesPrompt = MinutesComposer.defaultPrompt }
                    }
                }
            }

            Section("诊断日志") {
                LogView(lines: supervisor.logs)
                    .frame(minHeight: 160)
                HStack {
                    Button("清空") { supervisor.clearLogs() }
                    Button {
                        copyLogs()
                    } label: {
                        Label("复制日志", systemImage: "doc.on.doc")
                    }
                    .disabled(supervisor.logs.isEmpty)
                    .help("复制全部诊断日志")
                    Spacer()
                    Text("先运行 scripts/bootstrap.sh；首次使用再运行 scripts/download_models.sh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .padding()
    }

    private func copyLogs() {
        let formatter = ISO8601DateFormatter()
        let text = supervisor.logs.map { line in
            "[\(formatter.string(from: line.timestamp))] \(line.source) \(line.text)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func portBinding(for kind: EngineWorkerKind) -> Binding<Int> {
        Binding(
            get: { configuration.port(for: kind) },
            set: { configuration.setPort($0, for: kind) }
        )
    }
}

private struct PathField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        LabeledContent(title) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }
}

private struct ValidationText: View {
    let message: String?

    init(_ message: String?) {
        self.message = message
    }

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

private struct WorkerStatusPill: View {
    let kind: EngineWorkerKind
    let state: EngineWorker.State

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(kind.rawValue.uppercased())
                .font(.caption.monospaced())
        }
        .help("\(kind.displayName)：\(detail)")
    }

    private var color: Color {
        switch state {
        case .ready: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    private var detail: String {
        switch state {
        case .ready: return "就绪"
        case .starting: return "启动中"
        case .stopped: return "已停止"
        case .failed(let message): return message
        }
    }
}

private struct LogView: View {
    let lines: [EngineLogLine]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(lines) { line in
                    Text("\(line.source)  \(line.text)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(6)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
