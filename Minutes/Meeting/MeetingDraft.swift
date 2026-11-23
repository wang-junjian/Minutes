import Foundation

/// 草稿快照（ADR-0002）：会议未完成时的磁盘持久化状态。
///
/// `bufferStartSample` 是当前分段缓冲起点的采样偏移：其前的音频已落定
/// （或异常时按缓冲上限丢弃），恢复续录从 WAV 该偏移处读入尾部重建缓冲，
/// 不重新识别已落定部分。
struct MeetingDraft: Codable, Sendable {
    var meeting: Meeting
    var bufferStartSample: Int
}

/// 草稿快照的落盘与清理。平铺在 Meetings 目录，`<UUID>.draft` 扩展名
/// 避开 MeetingsStore 的 `.json` 加载；正常完成/放弃会删除草稿，
/// 因此启动时发现草稿即判定为中断会议。
@MainActor
final class MeetingDraftStore {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).draft")
    }

    func save(_ draft: MeetingDraft) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(draft)
        try data.write(to: url(for: draft.meeting.id), options: .atomic)
    }

    func load(id: UUID) -> MeetingDraft? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingDraft.self, from: data)
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
