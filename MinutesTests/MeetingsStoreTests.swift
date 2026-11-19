import XCTest
@testable import Minutes

@MainActor
final class MeetingsStoreTests: XCTestCase {
    func testSavePersistsAndReloadsMeeting() throws {
        let directory = makeDirectory()
        let store = MeetingsStore(directory: directory)
        let meeting = Meeting(
            id: UUID(), title: "持久化会议", createdAt: Date(timeIntervalSince1970: 1_000),
            duration: 12, segments: [], minutes: nil, transcriptText: "转写内容"
        )

        try store.save(meeting)
        let reloaded = MeetingsStore(directory: directory)

        XCTAssertEqual(reloaded.meetings, [meeting])
        XCTAssertNil(reloaded.errorMessage)
    }

    func testFailedUpdateKeepsLastDurableMeetingVisible() throws {
        let directory = makeDirectory()
        let store = MeetingsStore(directory: directory)
        let original = Meeting(id: UUID(), title: "已保存标题")
        try store.save(original)

        try FileManager.default.removeItem(at: directory)
        FileManager.default.createFile(atPath: directory.path, contents: Data())
        var updated = original
        updated.title = "未保存标题"
        XCTAssertThrowsError(try store.save(updated))

        XCTAssertEqual(store.meetings, [original])
        XCTAssertNotNil(store.errorMessage)
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
