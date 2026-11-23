import Foundation

/// 会议列表的本地持久化。JSON 文件，一会议一文件，人可直接查看。
@Observable
@MainActor
final class MeetingsStore {
    static let shared = MeetingsStore()

    private(set) var meetings: [Meeting] = []
    private(set) var errorMessage: String?

    let directory: URL

    convenience init() {
        #if DEBUG
        // 仅供本机 Debug 界面验证使用隔离数据，Release 始终使用 Application Support。
        if let override = ProcessInfo.processInfo.environment["MINUTES_MEETINGS_ROOT"], !override.isEmpty {
            self.init(directory: URL(fileURLWithPath: override, isDirectory: true))
            return
        }
        #endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("Minutes/Meetings", isDirectory: true)
        self.init(directory: directory)
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func reload() { load() }

    func save(_ meeting: Meeting) throws {
        do {
            try write(meeting)
            if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
                meetings[index] = meeting
            } else {
                meetings.insert(meeting, at: 0)
            }
            errorMessage = nil
        } catch {
            errorMessage = "保存会议失败：\(error.localizedDescription)"
            throw error
        }
    }

    func audioURL(for meeting: Meeting) -> URL {
        directory.appendingPathComponent("\(meeting.id.uuidString).wav")
    }

    /// 单独删除会议音频以释放空间，转写与纪要保留；文件已不存在视为成功。
    func deleteAudio(for meeting: Meeting) throws {
        do {
            try FileManager.default.removeItem(at: audioURL(for: meeting))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
        } catch {
            errorMessage = "删除音频失败：\(error.localizedDescription)"
            throw error
        }
        errorMessage = nil
    }

    func rejectBatchDeletion() {
        errorMessage = "请一次只删除一场会议。"
    }

    func delete(_ meeting: Meeting) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(for: meeting))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // 目标文件已经不存在时，磁盘已达到删除后的目标状态。
        } catch {
            errorMessage = "删除会议失败：\(error.localizedDescription)"
            throw error
        }
        // 级联清理附属文件，避免留下无人管理的残留（ADR-0002）。
        // 主 JSON 已删除，清理失败必须可观察而不是静默吞掉。
        var cleanupFailed = false
        for url in [audioURL(for: meeting), directory.appendingPathComponent("\(meeting.id.uuidString).draft")] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            } catch {
                cleanupFailed = true
                Log.error("级联清理失败 \(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        meetings.removeAll { $0.id == meeting.id }
        errorMessage = cleanupFailed
            ? "会议已删除，但部分音频或草稿文件清理失败，可在 Finder 中手动清理。"
            : nil
    }

    // MARK: - 私有

    private func fileURL(for meeting: Meeting) -> URL {
        // 文件名只由会议 id 决定：同一次会议反复保存只落一个文件，
        // 反复 save 不会产生带不同时间戳前缀的重复文件。
        directory.appendingPathComponent("\(meeting.id.uuidString).json")
    }

    private func write(_ meeting: Meeting) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meeting)
        try data.write(to: fileURL(for: meeting), options: .atomic)
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
