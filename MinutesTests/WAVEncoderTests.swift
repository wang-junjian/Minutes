import XCTest
@testable import Minutes

final class WAVEncoderTests: XCTestCase {
    func testHeaderAndPCM16LittleEndian() throws {
        let data = try WAVEncoder.encode([0, 1, -1])
        XCTAssertEqual(data.count, 50)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(readUInt32LE(data, at: 40), 6)
        XCTAssertEqual(readUInt16LE(data, at: 22), 1)
        XCTAssertEqual(readUInt32LE(data, at: 24), 16_000)
        XCTAssertEqual(readUInt16LE(data, at: 44), 0)
        XCTAssertEqual(readUInt16LE(data, at: 46), 32_767)
        XCTAssertEqual(readUInt16LE(data, at: 48), 32_769) // -32767 的位模式
    }

    func testEmptyAudioHasCanonical44ByteHeader() throws {
        let data = try WAVEncoder.encode([])
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(readUInt32LE(data, at: 4), 36)
        XCTAssertEqual(readUInt32LE(data, at: 40), 0)
    }

    func testNonFiniteSampleIsRejected() {
        XCTAssertThrowsError(try WAVEncoder.encode([.nan]))
        XCTAssertThrowsError(try WAVEncoder.encode([.infinity]))
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
