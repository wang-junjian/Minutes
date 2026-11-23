import SwiftUI

/// 进行中的会议视图：状态条 + 波形 + 实时转写。
struct LiveMeetingView: View {
    @Bindable var session: MeetingSession
    @State private var isPresentingDiscardConfirmation = false
    @State private var isDiscarding = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TranscriptView(segments: session.meeting.segments, interimText: session.interimText)
            Divider()
            controls
        }
        .navigationTitle(session.meeting.title.isEmpty ? "新会议" : session.meeting.title)
        .confirmationDialog("放弃这场会议？", isPresented: $isPresentingDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃会议", role: .destructive) {
                isDiscarding = true
                Task {
                    await session.discard()
                    isDiscarding = false
                }
            }
            Button("返回会议", role: .cancel) {}
        } message: {
            Text("未保存的转写与纪要将被丢弃，此操作无法撤销。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            StatusDot(phase: session.phase)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.headline)
                if let error = session.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if session.isTransitioning || session.phase == .composing {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Text(Formatters.clock(session.elapsed))
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.bar)
    }

    private var statusText: String {
        switch session.phase {
        case .live: return "正在聆听"
        case .paused: return "已暂停"
        case .composing:
            switch session.finishStage {
            case .transcribing: return "正在完成最后识别…"
            case .composing: return "正在生成纪要…"
            case .saving: return "正在保存会议…"
            case nil: return "正在完成会议…"
            }
        case .failed: return "会议尚未完成，可重试"
        case .completed: return "已完成"
        case .idle: return "就绪"
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            WaveformBars(levels: session.energyRing)
                .frame(height: 28)
                .frame(maxWidth: .infinity)

            if session.phase == .live {
                Button {
                    Task { await session.pause() }
                } label: {
                    Label("暂停", systemImage: "pause.circle.fill")
                }
                .disabled(session.isTransitioning || isDiscarding)
            } else if session.phase == .paused {
                Button {
                    Task { await session.resume() }
                } label: {
                    Label("继续", systemImage: "play.circle.fill")
                }
                .disabled(session.isTransitioning || isDiscarding)
            }

            Button(role: .destructive) {
                Task { await session.finish() }
            } label: {
                Label(session.phase == .failed ? "重试结束" : "结束并生成纪要", systemImage: "stop.circle.fill")
            }
            .disabled(session.isTransitioning || isDiscarding || session.phase == .composing || session.phase == .completed)

            Button(role: .destructive) {
                isPresentingDiscardConfirmation = true
            } label: {
                Label("放弃会议", systemImage: "trash")
            }
            .disabled(isDiscarding)
        }
        .padding()
        .background(.bar)
    }
}

/// 状态圆点：录音时呼吸闪烁。
private struct StatusDot: View {
    let phase: MeetingPhase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color, radius: phase == .live ? 4 : 0)
            .opacity(phase == .live ? pulsingOpacity : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsingOpacity)
    }

    private var color: Color {
        switch phase {
        case .live: return .red
        case .paused: return .yellow
        case .composing: return .blue
        case .failed: return .orange
        case .completed: return .green
        case .idle: return .secondary
        }
    }

    private var pulsingOpacity: Double { phase == .live ? 0.35 : 1 }
}
