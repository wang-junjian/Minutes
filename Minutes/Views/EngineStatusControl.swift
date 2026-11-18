import SwiftUI

/// 主界面工具栏中的模型状态，兼顾状态可见性与快捷启停。
struct EngineStatusControl: View {
    @Environment(EngineSupervisor.self) private var supervisor

    var body: some View {
        Menu {
            ForEach(EngineWorkerKind.allCases) { kind in
                Label {
                    Text("\(kind.displayName)：\(detail(for: supervisor.states[kind] ?? .stopped))")
                } icon: {
                    Image(systemName: iconName(for: supervisor.states[kind] ?? .stopped))
                        .foregroundStyle(color(for: supervisor.states[kind] ?? .stopped))
                }
            }

            if let failure = failureMessage {
                Text(failure)
            }

            Divider()
            Button {
                supervisor.startAll()
            } label: {
                Label("启动全部模型", systemImage: "play.fill")
            }
            Button(role: .destructive) {
                supervisor.stopAll()
            } label: {
                Label("停止全部模型", systemImage: "stop.fill")
            }
            .disabled(supervisor.states.values.allSatisfy { $0 == .stopped })
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(overallColor)
                    .frame(width: 8, height: 8)
                Text(overallStatus)
                    .font(.callout)
            }
        }
        .menuIndicator(.hidden)
        .help(helpText)
        .accessibilityLabel("模型状态：\(overallStatus)")
    }

    private var overallStatus: String {
        let states = EngineWorkerKind.allCases.map { supervisor.states[$0] ?? .stopped }
        if states.allSatisfy({ $0 == .ready }) { return "模型已就绪" }
        if states.contains(where: { if case .failed = $0 { return true }; return false }) {
            return "模型启动失败"
        }
        if states.contains(.starting) { return "模型启动中" }
        if states.contains(.ready) { return "模型部分就绪" }
        return "模型已停止"
    }

    private var overallColor: Color {
        let states = EngineWorkerKind.allCases.map { supervisor.states[$0] ?? .stopped }
        if states.allSatisfy({ $0 == .ready }) { return .green }
        if states.contains(where: { if case .failed = $0 { return true }; return false }) { return .red }
        if states.contains(.starting) || states.contains(.ready) { return .orange }
        return .secondary
    }

    private var failureMessage: String? {
        for kind in EngineWorkerKind.allCases {
            if case .failed(let message) = supervisor.states[kind] {
                return "\(kind.displayName)：\(message)"
            }
        }
        return nil
    }

    private var helpText: String {
        failureMessage ?? "点击查看语音识别和语言模型状态，或手动启停模型"
    }

    private func detail(for state: EngineWorker.State) -> String {
        switch state {
        case .ready: return "已就绪，随时待命"
        case .starting: return "启动中"
        case .stopped: return "已停止"
        case .failed(let message): return message
        }
    }

    private func color(for state: EngineWorker.State) -> Color {
        switch state {
        case .ready: return .green
        case .starting: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private func iconName(for state: EngineWorker.State) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .starting: return "arrow.triangle.2.circlepath"
        case .stopped: return "stop.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}
