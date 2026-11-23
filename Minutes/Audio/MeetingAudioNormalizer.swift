import Foundation

/// 回放前的非破坏性峰值归一化：只提升低音量 PCM16 WAV，不修改磁盘原文件。
/// 增益最高约 24 dB，峰值不超过 -1 dBFS，避免把正常录音再次放大或削波。
enum MeetingAudioNormalizer {
    private static let maximumGain: Float = 16
    private static let targetPeak: Int32 = 29_200

    static func normalizedData(at url: URL) throws -> Data {
        normalizedData(try Data(contentsOf: url))
    }

    static func normalizedData(_ source: Data) -> Data {
        // 会议音频由 WAVEncoder 生成，固定为 44 字节头部 + PCM16 负载。
        guard source.count >= 46 else { return source }
        let sampleCount = (source.count - 44) / 2

        let peak = source.withUnsafeBytes { raw -> Int32 in
            let samples = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            var peak: Int32 = 0
            for index in 0..<sampleCount {
                let sample = Int32(Int16(littleEndian: samples[index]))
                peak = max(peak, abs(sample))
            }
            return peak
        }
        guard peak > 0, peak < targetPeak else { return source }

        let gain = min(maximumGain, Float(targetPeak) / Float(peak))
        var output = source
        output.withUnsafeMutableBytes { raw in
            let samples = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            for index in 0..<sampleCount {
                let sample = Int32(Int16(littleEndian: samples[index]))
                let amplified = Int32((Float(sample) * gain).rounded())
                let clipped = max(-32_768, min(32_767, amplified))
                samples[index] = Int16(clipped).littleEndian
            }
        }
        return output
    }
}
