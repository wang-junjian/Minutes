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

    func testDeleteRemovesMemoryAndDiskWithoutResurrectingOnReload() throws {
        let directory = makeDirectory()
        let store = MeetingsStore(directory: directory)
        let meeting = Meeting(id: UUID(), title: "待删除会议")
        try store.save(meeting)

        try store.delete(meeting)

        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(for: meeting, in: directory).path))
        XCTAssertTrue(MeetingsStore(directory: directory).meetings.isEmpty)
    }

    func testFailedDeleteKeepsMeetingAndCanBeRetried() throws {
        let directory = makeDirectory()
        let store = MeetingsStore(directory: directory)
        let meeting = Meeting(id: UUID(), title: "不能静默删除")
        try store.save(meeting)
        let file = fileURL(for: meeting, in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        XCTAssertThrowsError(try store.delete(meeting))

        XCTAssertEqual(store.meetings, [meeting])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try store.delete(meeting)
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeleteTreatsAlreadyMissingFileAsSuccess() throws {
        let directory = makeDirectory()
        let store = MeetingsStore(directory: directory)
        let meeting = Meeting(id: UUID(), title: "已经不在磁盘")
        try store.save(meeting)
        try FileManager.default.removeItem(at: fileURL(for: meeting, in: directory))

        try store.delete(meeting)

        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testDeleteAlsoRemovesAudioAndDraft() throws {
        let directory = makeDirectory()
        let store = MeetingsStore(directory: directory)
        let meeting = Meeting(id: UUID(), title: "级联删除")
        try store.save(meeting)
        let audioURL = directory.appendingPathComponent("\(meeting.id.uuidString).wav")
        let draftURL = directory.appendingPathComponent("\(meeting.id.uuidString).draft")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0, 1]))
        FileManager.default.createFile(atPath: draftURL.path, contents: Data([2]))

        try store.delete(meeting)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testDeleteAudioKeepsMeetingAndTranscript() throws {
        let directory = makeDirectory()
        let store = MeetingsStore(directory: directory)
        let meeting = Meeting(
            id: UUID(), title: "释放空间", createdAt: Date(timeIntervalSince1970: 1_000),
            transcriptText: "转写保留"
        )
        try store.save(meeting)
        let audioURL = directory.appendingPathComponent("\(meeting.id.uuidString).wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0, 1]))

        try store.deleteAudio(for: meeting)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(store.meetings, [meeting])
        XCTAssertEqual(MeetingsStore(directory: directory).meetings, [meeting])
        XCTAssertNil(store.errorMessage)
    }

    func testDeleteAudioTreatsMissingFileAsSuccess() throws {
        let directory = makeDirectory()
        let store = MeetingsStore(directory: directory)
        let meeting = Meeting(id: UUID(), title: "无音频旧会议")
        try store.save(meeting)

        try store.deleteAudio(for: meeting)

        XCTAssertEqual(store.meetings, [meeting])
        XCTAssertNil(store.errorMessage)
    }

    private func fileURL(for meeting: Meeting, in directory: URL) -> URL {
        directory.appendingPathComponent("\(meeting.id.uuidString).json")
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
