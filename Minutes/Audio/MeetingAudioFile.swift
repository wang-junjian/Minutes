import Foundation

/// 会议音频文件：16 kHz 单声道 PCM16 WAV 的持续追加写入（ADR-0002）。
///
/// 从录制开始逐块追加，正常结束/暂停时 `finalize()` 回填头部长度；
/// 崩溃后头部为脏值，启动时 `repair(at:)` 按文件实际大小确定性修复。
/// 追加打开已存在文件用于暂停恢复与中断续录，音频偏移即录制时间轴。
final class MeetingAudioFile {
    private let handle: FileHandle

    init(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw MinutesError.audio("无法创建会议音频文件：\(url.lastPathComponent)")
            }
        }
        handle = try FileHandle(forUpdating: url)
        if try handle.seekToEnd() == 0 {
            try handle.write(contentsOf: WAVEncoder.header(dataSize: 0))
        }
    }

    /// 追加一段 16 kHz 单声道浮点采样，编码与 WAVEncoder 共享同一实现。
    func append(_ samples: [Float]) throws {
        guard samples.allSatisfy(\.isFinite) else {
            throw MinutesError.audio("PCM 包含非有限采样值")
        }
        try handle.write(contentsOf: WAVEncoder.pcm16Data(samples))
    }

    /// 回填头部长度；文件可继续追加（恢复续录）。
    func finalize() throws {
        try Self.repairHeader(handle: handle)
    }

    /// 崩溃恢复：按文件实际大小修复头部。文件不存在时无音频可修，直接返回。
    static func repair(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try repairHeader(handle: handle)
    }

    /// 读取全部采样（恢复续录重建缓冲用）；文件缺失或不足头部时返回空。
    static func readSamples(at url: URL) throws -> [Float] {
        guard let data = try? Data(contentsOf: url), data.count >= 44 else { return [] }
        let payload = data.dropFirst(44).prefix((data.count - 44) / 2 * 2)
        return payload.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            return ints.map { Float(Int16(littleEndian: $0)) / 32_767 }
        }
    }

    private static func repairHeader(handle: FileHandle) throws {
        let size = try handle.seekToEnd()
        // 崩溃可能写在 PCM16 采样中间：残缺尾字节向下取偶并截断。
        let dataSize = size >= 44 ? ((size - 44) / 2) * 2 : 0
        try handle.truncate(atOffset: 44 + dataSize)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVEncoder.header(dataSize: UInt32(dataSize)))
        try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }
}
