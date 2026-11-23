import Foundation

/// 会议列表的本地持久化。JSON 文件，一会议一文件，人可直接查看。
@Observable
@MainActor
final class MeetingsStore {
    static let shared = MeetingsStore()

    private(set) var meetings: [Meeting] = []

    private let directory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = appSupport.appendingPathComponent("Minutes/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func reload() { load() }

    func save(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        write(meeting)
    }

    func delete(_ meeting: Meeting) {
        meetings.removeAll { $0.id == meeting.id }
        try? FileManager.default.removeItem(at: fileURL(for: meeting))
    }

    // MARK: - 私有

    private func fileURL(for meeting: Meeting) -> URL {
        // 文件名只由会议 id 决定：同一次会议反复保存只落一个文件，
        // 反复 save 不会产生带不同时间戳前缀的重复文件。
        directory.appendingPathComponent("\(meeting.id.uuidString).json")
    }

    private func write(_ meeting: Meeting) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(meeting) else { return }
        try? data.write(to: fileURL(for: meeting), options: .atomic)
    }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        meetings = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
