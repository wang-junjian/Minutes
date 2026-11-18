import SwiftUI

/// 转写片段列表，自动滚到底部。
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    /// 识别中的中间文本（可选），灰色显示在列表末尾。
    var interimText: String = ""

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if segments.isEmpty && interimText.isEmpty {
                    Text("等待发言…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(segments.sorted(by: { $0.sequence < $1.sequence })) { segment in
                        TranscriptRow(segment: segment)
                            .id(segment.id)
                    }
                    if !interimText.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "waveform")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(width: 100, alignment: .leading)
                            Text(interimText)
                                .foregroundStyle(.secondary)
                                .italic()
                        }
                        .id("interim")
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.plain)
            .onChange(of: segments.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: interimText) {
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if !interimText.isEmpty {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("interim", anchor: .bottom)
            }
        } else if let last = segments.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(Formatters.stamp(segment.start)) – \(Formatters.stamp(segment.end))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(segment.text)
                .textSelection(.enabled)
            if let language = segment.language {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 简易波形条：给定一组 0...1 的能量值绘制圆角竖条。
struct WaveformBars: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: max(3, CGFloat(level) * 28))
            }
        }
        .drawingGroup()
    }
}
