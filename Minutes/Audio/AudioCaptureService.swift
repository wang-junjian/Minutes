import AVFoundation

/// 从麦克风采集的原始块：16 kHz 单声道 float32。
struct CapturedChunk: Sendable {
    let samples: [Float]
    /// 块的均方根能量，用于波形显示。
    let rms: Float
}

/// 麦克风采集服务。
///
/// 血泪教训（两个坑都踩过）：
///  1. installTap 的 format 必须传总线原生格式——请求其他采样率会直接 SIGSEGV；
///  2. AVAudioConverter 不能跨缓冲复用——它是有状态的，用错会静默丢数据。
/// 所以这里的做法是：tap 按原生格式收，每个缓冲用一次性 converter 转 16 kHz，
/// 无状态、可重入，代价是每次约零点几毫秒的转换器创建开销。
final class AudioCaptureService: @unchecked Sendable {
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var stream: AsyncStream<CapturedChunk>?
    private var continuation: AsyncStream<CapturedChunk>.Continuation?

    init() {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    /// 返回采集流。再次调用前先 stop()。
    func start() throws -> AsyncStream<CapturedChunk> {
        guard !isRunning else { throw MinutesError.audio("采集已在运行") }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MinutesError.audio("麦克风不可用（检查系统隐私权限）")
        }

        let stream = AsyncStream<CapturedChunk>(bufferingPolicy: .bufferingNewest(64)) { continuation in
            self.continuation = continuation
        }
        self.stream = stream

        // 务必用原生格式 tap；重采样在 handleInput 里做。
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }
        try engine.start()
        isRunning = true
        Log.audio("采集开始：输入 \(inputFormat.sampleRate) Hz \(inputFormat.channelCount) ch")
        return stream
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        continuation?.finish()
        continuation = nil
        stream = nil
        Log.audio("采集停止")
    }

    // MARK: - 私有

    /// 回调在实时音频线程上。tap 给的是原生格式，这里逐缓冲转成 16 kHz。
    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard let continuation else { return }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat),
              let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if !consumed {
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            status.pointee = .endOfStream
            return nil
        }
        guard error == nil, output.frameLength > 0 else { return }

        let frameLength = Int(output.frameLength)
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: frameLength))
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = sqrt(sum / Float(frameLength))
        continuation.yield(CapturedChunk(samples: samples, rms: rms))
    }
}
