import XCTest
@testable import Minutes

@MainActor
final class MeetingDraftTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingDraftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoadAllScansDraftsSkipsCorruptedAndOtherFiles() throws {
        let store = MeetingDraftStore(directory: directory)
        let earlier = Meeting(
            title: "较早", createdAt: Date(timeIntervalSince1970: 1_000), duration: 12
        )
        let later = Meeting(
            title: "较晚", createdAt: Date(timeIntervalSince1970: 2_000), duration: 30
        )
        try store.save(MeetingDraft(meeting: later, bufferStartSample: 480_000))
        try store.save(MeetingDraft(meeting: earlier, bufferStartSample: 192_000))

        // 干扰项：损坏草稿、已完成会议 JSON、会议音频。
        directory.appendingPathComponent("\(UUID().uuidString).draft")
            .write(Data("not json".utf8))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        try Data([0, 1]).write(to: directory.appendingPathComponent("\(UUID().uuidString).wav"))

        let drafts = store.loadAll()
        XCTAssertEqual(drafts.map(\.meeting.title), ["较早", "较晚"])
        XCTAssertEqual(drafts.map(\.bufferStartSample), [192_000, 480_000])
    }
}

private extension URL {
    func write(_ data: Data) {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
