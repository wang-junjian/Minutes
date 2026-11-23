import Foundation

/// 将采集器输出的 16 kHz 单声道浮点 PCM 编码为标准 PCM16 WAV。
/// 头部与 PCM16 转换为共享实现：整段编码与会议音频流式写入（ADR-0002）
/// 共用同一份字节格式，避免两处漂移。
enum WAVEncoder {
    static let sampleRate = 16_000

    static func encode(_ samples: [Float]) throws -> Data {
        guard samples.count <= (Int(UInt32.max) - 36) / 2 else {
            throw MinutesError.audio("音频过长，无法编码为 WAV")
        }
        guard samples.allSatisfy(\.isFinite) else {
            throw MinutesError.audio("PCM 包含非有限采样值")
        }

        var data = header(dataSize: UInt32(samples.count * 2))
        data.append(pcm16Data(samples))
        return data
    }

    /// 44 字节 PCM16 WAV 头。
    static func header(dataSize: UInt32) -> Data {
        var data = Data()
        data.reserveCapacity(44)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32LE(36 + dataSize, to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendUInt32LE(16, to: &data)                 // PCM chunk size
        appendUInt16LE(1, to: &data)                  // PCM format
        appendUInt16LE(1, to: &data)                  // mono
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(UInt32(sampleRate * 2), to: &data)
        appendUInt16LE(2, to: &data)                  // block align
        appendUInt16LE(16, to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32LE(dataSize, to: &data)
        return data
    }

    /// 浮点采样 → PCM16 little-endian 字节。
    static func pcm16Data(_ samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            let value = Int16((clipped * 32_767).rounded())
            appendUInt16LE(UInt16(bitPattern: value), to: &data)
        }
        return data
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
