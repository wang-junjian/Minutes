import Foundation

/// 一条转写片段，对应节奏分段落定的一段文字。
struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// 相对会议开始的秒数。
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// 识别出的语言代码（如 zh / en），未知则为 nil。
    var language: String?
    /// 发送给引擎的顺序号，用于乱序响应归位。
    var sequence: Int
}

/// 会议纪要的结构化结果。
struct MinutesDocument: Codable, Hashable, Sendable {
    var summary: String = ""
    var decisions: [String] = []
    var actionItems: [String] = []
    var keywords: [String] = []
}

enum MeetingPhase: String, Codable, Sendable {
    case idle      // 未开始
    case live      // 录制中转写
    case paused    // 暂停
    case composing // 生成纪要中
    case completed // 已结束
}

/// 一场会议的持久化模型。JSON 落盘，可人工检查。
struct Meeting: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var duration: TimeInterval = 0
    var segments: [TranscriptSegment] = []
    var minutes: MinutesDocument?
    var transcriptText: String = ""

    static let empty = Meeting(title: "")
}

/// 渲染给视图的一行引擎日志。
struct EngineLogLine: Identifiable, Hashable, Sendable {
    let id = UUID()
    let timestamp: Date
    let source: String
    let text: String
}

enum MinutesError: LocalizedError, Sendable {
    case engineNotReady(worker: String)
    case network(String)
    case decoding(String)
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .engineNotReady(let worker):
            return "推理引擎 \(worker) 尚未就绪"
        case .network(let detail):
            return "网络请求失败：\(detail)"
        case .decoding(let detail):
            return "响应解析失败：\(detail)"
        case .audio(let detail):
            return "音频系统错误：\(detail)"
        }
    }
}

enum Formatters {
    /// 62.5 → "01:02"
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 相对秒数 → "00:12"
    static func stamp(_ seconds: TimeInterval) -> String {
        clock(seconds)
    }
}
