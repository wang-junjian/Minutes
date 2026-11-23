import XCTest
@testable import Minutes

final class MeetingAudioNormalizerTests: XCTestCase {
    func testQuietAudioIsBoostedWithoutChangingHeader() throws {
        let source = try WAVEncoder.encode([0.01, -0.02, 0.03])

        let output = MeetingAudioNormalizer.normalizedData(source)

        XCTAssertEqual(output.prefix(44), source.prefix(44))
        XCTAssertEqual(pcm16(output), pcm16(source).map { Int16(clamping: Int32($0) * 16) })
    }

    func testBoostIsPeakLimitedToPreventClipping() throws {
        let source = try WAVEncoder.encode([0.1, -0.2, 0.05])

        let output = MeetingAudioNormalizer.normalizedData(source)

        XCTAssertEqual(pcm16(output).map(Int32.init).map(abs).max(), 29_200)
        XCTAssertEqual(output.count, source.count)
    }

    func testLoudAudioIsNotAttenuatedOrAmplified() throws {
        let source = try WAVEncoder.encode([0.95, -0.5, 0.25])

        XCTAssertEqual(MeetingAudioNormalizer.normalizedData(source), source)
    }

    func testSilentAudioRemainsUnchanged() throws {
        let source = try WAVEncoder.encode([0, 0, 0])

        XCTAssertEqual(MeetingAudioNormalizer.normalizedData(source), source)
    }

    private func pcm16(_ data: Data) -> [Int16] {
        data.dropFirst(44).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) }
        }
    }
}
