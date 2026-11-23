import Foundation

/// ASR 并发闸门：限制同时发往识别引擎的请求数。
///
/// 固定节奏的识别请求若不加限制，突发时会压垮本地推理引擎
/// （排队雪崩、超时、结果丢失）。用计数信号量排队。
actor TranscriptionGate {
    private let limit: Int
    private var current = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 2) { self.limit = limit }

    /// 阻塞获取一个名额；没有名额则排队等待。
    func acquire() async {
        if current < limit {
            current += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 非阻塞获取：有名额就拿，没有返回 false（中间结果识别用，宁可丢不可堵）。
    func tryAcquire() -> Bool {
        if current < limit {
            current += 1
            return true
        }
        return false
    }

    func release() {
        guard current > 0 else { return }
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            current -= 1
        }
    }
}

/// 会议会话：把采集 → 节奏识别 → 纪要 串成一条流水线。
///
/// 不用 VAD：能量阈值在复杂声学环境下不可靠（噪声爬升漏检、切句点断词）。
/// 改为固定节奏把缓冲音频送 ASR，文本实时上屏，断句由识别文本的句读
/// 决定（句末标点 + 最小时长），或超长强制切段。
///
/// 只依赖协议与 actor，不直接触碰视图；视图通过 @Observable 投影状态。
@Observable
@MainActor
final class MeetingSession {
    private(set) var meeting: Meeting
    private(set) var phase: MeetingPhase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var composedText: String = ""      // 纪要生成过程中的流式文本
    /// 正在识别中的中间文本（灰色显示，终稿到达后被替换）。
    private(set) var interimText: String = ""
    private(set) var errorMessage: String?

    /// 波形能量环，供实时界面绘制（0 被覆盖旧值）。
    private(set) var energyRing: [Float] = Array(repeating: 0, count: 60)

    let engineSupervisor: EngineSupervisor
    private let capture = AudioCaptureService()
    private let client = EngineClient.shared
    private let store: MeetingsStore

    private let gate = TranscriptionGate(limit: 2)
    private var pipelineTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var sequenceCounter = 0
    private var pendingSequences: [Int: TranscriptSegment] = [:]
    private var nextExpectedSequence = 0

    // MARK: - 节奏分段缓冲（无 VAD）
    //
    // 音频持续累积进 buffer；每 pollInterval 秒送一次 ASR，结果整体替换
    // 中间文本；识别文本以句读标点收尾且音频足够长，或段长超上限时，
    // 落成正式分段并开始新缓冲。断句由 ASR 文本决定，不依赖能量阈值。

    /// 当前分段的音频缓冲与首尾偏移。
    private var buffer: [Float] = []
    private var bufferStart: TimeInterval = 0
    private var bufferEnd: TimeInterval = 0
    /// 上次送识别的缓冲时长（缓冲内相对秒）。
    private var lastPollAt: TimeInterval = 0
    /// 送识别节奏（秒）。
    private let pollInterval: TimeInterval = 1.5
    /// 以句读收尾时切段所需的最短音频（秒）。
    private let minCloseSeconds: TimeInterval = 5
    /// 不切句也强制切段的上限（秒）。
    private let maxSegmentSeconds: TimeInterval = 15
    /// 缓冲上限：引擎长时间不可用（如崩溃自愈中）时，丢弃超龄音频，
    /// 防止内存无界增长。留 60s，够覆盖自愈窗口。
    private let bufferCapSeconds: TimeInterval = 60
    private static let terminalPunctuation: String = "。！？!?；;…"

    private func appendToBuffer(_ chunk: CapturedChunk, offset: TimeInterval) {
        if buffer.isEmpty { bufferStart = offset }
        buffer.append(contentsOf: chunk.samples)
        bufferEnd = offset + Double(chunk.samples.count) / 16000.0
        var bufferLength = bufferEnd - bufferStart
        if bufferLength > bufferCapSeconds {
            let drop = Int((bufferLength - bufferCapSeconds) * 16000)
            buffer.removeFirst(drop)
            bufferStart = bufferEnd - bufferCapSeconds
            bufferLength = bufferCapSeconds
        }
        if bufferLength - lastPollAt >= pollInterval {
            lastPollAt = bufferLength
            Task { await self.pollRecognition() }
        }
    }

    /// 按节奏送当前缓冲识别；结果上屏并判断是否切段。
    private func pollRecognition() async {
        guard !buffer.isEmpty else { return }
        guard engineSupervisor.states[.asr] == .ready else { return }
        // 快照缓冲：识别期间缓冲继续增长，互不影响。
        let samples = buffer
        let generation = interimGeneration
        guard await gate.tryAcquire() else { return }
        let text: String
        do {
            let result = try await client.transcribe(samples, baseURL: engineSupervisor.configuration.baseURL(for: .asr))
            text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await gate.release()
            Log.info("节奏识别失败（可忽略）：\(error.localizedDescription)")
            return
        }
        await gate.release()
        guard generation == interimGeneration else { return }   // 缓冲已被切段/冲刷，结果作废

        let bufferLength = bufferEnd - bufferStart
        let endsAtSentence = text.count >= 2 && Self.terminalPunctuation.contains(text.last ?? " ")
        if (endsAtSentence && bufferLength >= minCloseSeconds) || bufferLength >= maxSegmentSeconds {
            closeSegment(text: text, start: bufferStart, end: bufferEnd)
        } else if !text.isEmpty {
            interimText = text
        }
    }

    /// 落定当前分段：有字落字，无字仅重置缓冲（长静音不产生空段）。
    private func closeSegment(text: String, start: TimeInterval, end: TimeInterval) {
        interimText = ""
        interimGeneration += 1
        lastPollAt = 0
        if !text.isEmpty {
            appendSegment(TranscriptSegment(
                start: start, end: end, text: text,
                language: nil, sequence: 0   // sequence 由 appendSegment 分配
            ))
        }
        buffer = []
        bufferStart = end
        bufferEnd = end
    }

    /// 会议结束时冲刷缓冲里的剩余音频。
    private func flushBuffer() async {
        guard !buffer.isEmpty else { return }
        interimGeneration += 1
        if engineSupervisor.states[.asr] == .ready {
            await gate.acquire()
            do {
                let result = try await client.transcribe(buffer, baseURL: engineSupervisor.configuration.baseURL(for: .asr))
                await gate.release()
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    appendSegment(TranscriptSegment(
                        start: bufferStart, end: bufferEnd, text: text,
                        language: result.language, sequence: 0
                    ))
                }
            } catch {
                await gate.release()
                Log.error("冲刷识别失败：\(error.localizedDescription)")
            }
        }
        buffer = []
        interimText = ""
    }

    /// 诊断：UserDefaults `debugCapture` 打开时把采集的原始 PCM 落盘，
    /// 用于区分「麦克风没声」与「识别没触发」。默认关闭，正常路径零开销。
    private var debugFile: FileHandle?

    init(store: MeetingsStore, engineSupervisor: EngineSupervisor = .shared) {
        self.store = store
        self.engineSupervisor = engineSupervisor
        // 每次新建会议必须生成新的 Meeting（新 id）。
        // 曾共用 store.draft 的副本，所有新会议 id 相同，后一个会把前一个
        // 在列表和磁盘上整体覆盖——「新建会议把上一个会议整没了」的元凶。
        self.meeting = Meeting(title: "")
    }

    var isLive: Bool { phase == .live }

    // MARK: - 控制

    func start() {
        guard phase == .idle || phase == .paused else { return }
        guard engineSupervisor.states[.asr] == .ready else {
            errorMessage = "语音识别引擎未就绪，请先在设置中启动引擎。"
            return
        }
        errorMessage = nil
        phase = .live
        meeting.createdAt = Date()

        clockTask = Task { [weak self] in
            guard let startedAt = self?.meeting.createdAt else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(startedAt) - self.meeting.duration
            }
        }

        pipelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try self.capture.start()
                if UserDefaults.standard.bool(forKey: "debugCapture") { self.openDebugFile() }
                let startTime = Date()
                for await chunk in stream {
                    if Task.isCancelled { break }
                    let offset = Date().timeIntervalSince(startTime)
                    self.pushEnergy(chunk.rms)
                    if self.debugFile != nil { self.recordDebug(chunk) }
                    self.appendToBuffer(chunk, offset: offset)
                }
                // 冲刷收尾的音频。
                await self.flushBuffer()
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription; self.phase = .idle }
            }
        }
    }

    func pause() {
        guard phase == .live else { return }
        phase = .paused
        meeting.duration = elapsed
        pipelineTask?.cancel(); pipelineTask = nil
        clockTask?.cancel(); clockTask = nil
        capture.stop()
        closeDebugFile()
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .idle   // start() 只允许 idle/paused，复用前重置
        start()
    }

    /// 结束会议：停采集，生成纪要。
    func finish() async {
        guard phase == .live || phase == .paused else { return }
        pause()
        phase = .composing
        meeting.duration = max(elapsed, meeting.duration)
        await composeMinutes()
        meeting.transcriptText = meeting.segments.map(\.text).joined(separator: "\n")
        // 标题优先用 LLM 根据内容起名，失败或未配引擎时用时间戳兜底。
        if meeting.title.isEmpty {
            meeting.title = await generateTitle() ?? Self.defaultTitle(for: meeting)
        }
        store.save(meeting)
        phase = .completed
    }

    /// 根据纪要摘要（或转写开头）起一个 ≤15 字的会议标题。
    private func generateTitle() async -> String? {
        guard engineSupervisor.states[.llm] == .ready else { return nil }
        let basis = !(meeting.minutes?.summary.isEmpty ?? true)
            ? (meeting.minutes?.summary ?? "")
            : String(meeting.transcriptText.prefix(600))
        guard !basis.isEmpty else { return nil }
        let messages = [
            EngineClient.ChatMessage(role: "system", content: "用不超过15个字概括会议主题，只输出标题本身，不要标点、引号或任何解释。"),
            EngineClient.ChatMessage(role: "user", content: basis),
        ]
        do {
            let raw = try await collectChat(messages, streamToScreen: false)
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^[\"'「『]+|[\"'」』。．.]+$", with: "", options: .regularExpression)
            guard !title.isEmpty, title.count <= 30 else { return nil }
            return title
        } catch {
            Log.info("生成标题失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - ASR

    /// 中间结果代次：缓冲每次切段/冲刷 +1，防止在飞的过期识别结果
    /// 把已落定的分段覆盖（对齐 qwenasr-studio 的 segGen 设计）。
    private var interimGeneration = 0

    /// 分段落盘：分配 sequence 并按序归位，保证转写不串行
    /// （识别任务完成先后不一，乱序到达是常态）。
    private func appendSegment(_ segment: TranscriptSegment) {
        var segment = segment
        segment.sequence = sequenceCounter
        sequenceCounter += 1
        pendingSequences[segment.sequence] = segment
        drainOrderedSegments()
    }

    /// 按序落盘。
    private func drainOrderedSegments() {
        while let next = pendingSequences[nextExpectedSequence] {
            pendingSequences.removeValue(forKey: nextExpectedSequence)
            meeting.segments.append(next)
            nextExpectedSequence += 1
        }
    }

    // MARK: - 纪要

    private func composeMinutes() async {
        guard engineSupervisor.states[.llm] == .ready else {
            composedText = "（语言模型引擎未就绪，仅保留转写原文。）"
            return
        }
        let segments = meeting.segments.sorted { $0.sequence < $1.sequence }
        // 单次调用的转写预算：留足输出空间，2 小时会议也不会撑爆模型窗口。
        let transcript = segments
            .map { "[\(Formatters.stamp($0.start))] \($0.text)" }
            .joined(separator: "\n")
        let blocks = MinutesComposer.makeBlocks(transcript, maxChars: 12_000)
        // 用户可在设置中自定义的纪要提示词。
        let prompt = engineSupervisor.configuration.minutesPrompt

        composedText = ""
        do {
            let finalText: String
            if blocks.count <= 1 {
                finalText = try await collectChat([
                    EngineClient.ChatMessage(role: "system", content: prompt),
                    EngineClient.ChatMessage(role: "user", content: MinutesComposer.userPrompt(transcript: blocks.first ?? "")),
                ])
            } else {
                // 长会议 map-reduce：逐块压成素材，再把素材汇总成正式纪要。
                // 每块 1.2 万字以内，LLM 单次调用的输入规模恒定。
                var drafts: [String] = []
                for (index, block) in blocks.enumerated() {
                    composedText += "\n—— 第 \(index + 1)/\(blocks.count) 段整理 ——\n"
                    let draft = try await collectChat([
                        EngineClient.ChatMessage(role: "system", content: MinutesComposer.compressionSystemPrompt),
                        EngineClient.ChatMessage(role: "user", content: "会议转写第 \(index + 1) 段（共 \(blocks.count) 段）：\n\n\(block)"),
                    ])
                    drafts.append("第 \(index + 1) 段：\n\(draft)")
                }
                composedText += "\n—— 汇总纪要 ——\n"
                finalText = try await collectChat([
                    EngineClient.ChatMessage(role: "system", content: prompt),
                    EngineClient.ChatMessage(role: "user", content: MinutesComposer.userPrompt(transcript: drafts.joined(separator: "\n\n"))),
                ])
            }
            meeting.minutes = MinutesComposer.parse(finalText)
        } catch {
            composedText += "\n\n（生成中断：\(error.localizedDescription)）"
        }
    }

    /// 发一次对话并收集流式输出。streamToScreen 为 true 时全程追加到
    /// composedText 实时上屏（纪要生成）；起标题这类旁路调用传 false。
    private func collectChat(_ messages: [EngineClient.ChatMessage], streamToScreen: Bool = true) async throws -> String {
        var output = ""
        for try await token in await client.streamChat(messages: messages, baseURL: engineSupervisor.configuration.baseURL(for: .llm)) {
            output += token
            if streamToScreen { composedText += token }
        }
        return output
    }

    // MARK: - 工具

    private func pushEnergy(_ rms: Float) {
        energyRing.removeFirst()
        energyRing.append(min(rms * 12, 1))
    }

    // MARK: - 诊断采集（UserDefaults `debugCapture` 开关，默认关闭）

    private func openDebugFile() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("debug_last_capture.f32")
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        debugFile = try? FileHandle(forWritingTo: url)
    }

    private func recordDebug(_ chunk: CapturedChunk) {
        chunk.samples.withUnsafeBytes { raw in
            if let base = raw.baseAddress { debugFile?.write(Data(bytes: base, count: raw.count)) }
        }
    }

    private func closeDebugFile() {
        debugFile?.closeFile()
        debugFile = nil
    }

    private static func defaultTitle(for meeting: Meeting) -> String {
        Self.titleFormatter.string(from: meeting.createdAt) + " 会议"
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}
