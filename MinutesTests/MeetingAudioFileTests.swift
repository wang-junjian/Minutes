import XCTest
@testable import Minutes

final class MeetingAudioFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFinalizeWritesCompleteWAVMatchingEncoder() throws {
        let url = directory.appendingPathComponent("audio.wav")
        let first: [Float] = [0, 0.5, -0.5, 1, -1]
        let second: [Float] = [0.25, -0.25, 0.125]

        let file = try MeetingAudioFile(at: url)
        try file.append(first)
        try file.append(second)
        try file.finalize()

        XCTAssertEqual(try Data(contentsOf: url), try WAVEncoder.encode(first + second))
    }

    func testRepairRestoresHeaderAfterCrash() throws {
        let url = directory.appendingPathComponent("audio.wav")
        let samples: [Float] = [0.5, -0.5, 0.25]

        // 崩溃现场：追加后没来得及 finalize，头部长度仍是脏值。
        let file = try MeetingAudioFile(at: url)
        try file.append(samples)

        try MeetingAudioFile.repair(at: url)

        XCTAssertEqual(try Data(contentsOf: url), try WAVEncoder.encode(samples))
    }

    func testReopeningAppendsForResume() throws {
        let url = directory.appendingPathComponent("audio.wav")
        let beforePause: [Float] = [0.5, -0.5]
        let afterResume: [Float] = [0.25, -0.25, 0.125]

        let first = try MeetingAudioFile(at: url)
        try first.append(beforePause)
        try first.finalize()

        let second = try MeetingAudioFile(at: url)
        try second.append(afterResume)
        try second.finalize()

        XCTAssertEqual(try Data(contentsOf: url), try WAVEncoder.encode(beforePause + afterResume))
    }

    func testRepairTruncatesPartialSampleFromCrash() throws {
        let url = directory.appendingPathComponent("audio.wav")
        let samples: [Float] = [0.5, -0.5, 0.25]

        let file = try MeetingAudioFile(at: url)
        try file.append(samples)
        // 崩溃写在一个 PCM16 采样的中间：文件尾多出 1 个残缺字节。
        let handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xAB]))
        try handle.close()

        try MeetingAudioFile.repair(at: url)

        XCTAssertEqual(try Data(contentsOf: url), try WAVEncoder.encode(samples))
    }
}
