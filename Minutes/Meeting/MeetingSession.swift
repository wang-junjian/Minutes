import Foundation

protocol MeetingAudioCapturing: AnyObject {
    func start() throws -> AsyncStream<CapturedChunk>
    func stop()
}

extension AudioCaptureService: MeetingAudioCapturing {}

protocol MeetingTranscribing: Sendable {
    func transcribe(_ samples: [Float], baseURL: URL) async throws -> EngineClient.ASRResult
}

extension EngineClient: MeetingTranscribing {}

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
    /// 正在识别中的中间文本（灰色显示，终稿到达后被替换）。
    private(set) var interimText: String = ""
    private(set) var errorMessage: String?
    private(set) var isTransitioning = false

    enum FinishStage: String, Sendable {
        case transcribing
        case composing
        case saving
    }

    private(set) var finishStage: FinishStage?

    /// 波形能量环，供实时界面绘制（0 被覆盖旧值）。
    private(set) var energyRing: [Float] = Array(repeating: 0, count: 60)

    let engineSupervisor: EngineSupervisor
    private let capture: any MeetingAudioCapturing
    private let transcriber: any MeetingTranscribing
    private let chat: any MeetingChatStreaming
    private let store: MeetingsStore
    private let readiness: ((EngineWorkerKind) -> Bool)?
    private let now: () -> Date
    private let titleTimeout: TimeInterval
    private var hasStarted = false
    private var recordingStartedAt: Date?
    private var recordedSampleCount = 0

    /// 会议音频：录制期间持续追加落盘，暂停/结束时回填头部（ADR-0002）。
    private var audioFile: MeetingAudioFile?
    private var audioURL: URL {
        store.directory.appendingPathComponent("\(meeting.id.uuidString).wav")
    }

    private func openAudioFileIfNeeded() {
        guard audioFile == nil else { return }
        do {
            audioFile = try MeetingAudioFile(at: audioURL)
        } catch {
            errorMessage = "音频自动保存失败：\(error.localizedDescription)"
        }
    }

    private func recordAudio(_ chunk: CapturedChunk) {
        guard let audioFile else { return }
        do {
            try audioFile.append(chunk.samples)
        } catch {
            self.audioFile = nil
            errorMessage = "音频自动保存失败：\(error.localizedDescription)"
        }
    }

    private func closeAudioFile() {
        do {
            try audioFile?.finalize()
        } catch {
            Log.error("音频头部回填失败：\(error.localizedDescription)")
        }
        audioFile = nil
    }

    // MARK: - 草稿快照（落定即写 + 定时兜底，完成/放弃清理）

    private let drafts: MeetingDraftStore
    private let draftInterval: TimeInterval
    private var draftTask: Task<Void, Never>?

    /// 自动保存失败只呈现警告，不阻断录制。
    private func saveDraft() {
        // live 期间 duration 尚未固化进 meeting，快照写盘时实时刷新时长
        // （不依赖时钟任务的更新节奏），否则恢复显示与续录时长会和音频
        // 偏移分叉（ADR-0001）。
        updateElapsed()
        var snapshotMeeting = meeting
        snapshotMeeting.duration = max(meeting.duration, elapsed)
        let draft = MeetingDraft(
            meeting: snapshotMeeting,
            bufferStartSample: Int((bufferStart * 16_000).rounded())
        )
        do {
            try drafts.save(draft)
        } catch {
            errorMessage = "自动保存失败：\(error.localizedDescription)"
        }
    }

    private func startDraftTask() {
        draftTask?.cancel()
        draftTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.draftInterval ?? 15) * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.saveDraft()
            }
        }
    }

    private let gate = TranscriptionGate(limit: 2)
    private var pipelineTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var recognitionTasks: [Int: Task<Void, Never>] = [:]
    private var transcriptFinalized = false
    private var isDiscarding = false

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

    private struct RecognitionSnapshot {
        let id: Int
        let samples: [Float]
        let start: TimeInterval
        let end: TimeInterval
        let generation: Int
    }

    private var nextSnapshotID = 0
    private var latestSnapshotID = 0
    private var failedSnapshots: [Int: RecognitionSnapshot] = [:]
    private var unresolvedSnapshot: RecognitionSnapshot?

    private func makeSnapshot() -> RecognitionSnapshot {
        nextSnapshotID += 1
        let snapshot = RecognitionSnapshot(
            id: nextSnapshotID, samples: buffer, start: bufferStart, end: bufferEnd,
            generation: interimGeneration
        )
        latestSnapshotID = snapshot.id
        return snapshot
    }

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
            let snapshot = makeSnapshot()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.pollRecognition(snapshot)
            }
            recognitionTasks[snapshot.id] = task
        }
    }

    /// 按节奏送当前缓冲识别；结果上屏并判断是否切段。
    private func pollRecognition(_ snapshot: RecognitionSnapshot) async {
        defer { recognitionTasks[snapshot.id] = nil }
        guard snapshot.generation == interimGeneration, !buffer.isEmpty else { return }
        guard isReady(.asr) else { return }
        guard await gate.tryAcquire() else { return }
        let result: EngineClient.ASRResult
        do {
            result = try await transcriber.transcribe(
                snapshot.samples, baseURL: engineSupervisor.configuration.baseURL(for: .asr)
            )
        } catch {
            await gate.release()
            if snapshot.generation == interimGeneration {
                failedSnapshots[snapshot.id] = snapshot
            }
            Log.info("节奏识别失败（可忽略）：\(error.localizedDescription)")
            return
        }
        await gate.release()
        applyRecognitionResult(result, to: snapshot)
    }

    private func applyRecognitionResult(_ result: EngineClient.ASRResult, to snapshot: RecognitionSnapshot) {
        guard snapshot.generation == interimGeneration else { return }
        failedSnapshots = failedSnapshots.filter { $0.value.end > snapshot.end }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let snapshotLength = snapshot.end - snapshot.start
        let endsAtSentence = text.count >= 2 && Self.terminalPunctuation.contains(text.last ?? " ")
        if ((endsAtSentence && snapshotLength >= minCloseSeconds) || snapshotLength >= maxSegmentSeconds),
           snapshot.start == bufferStart {
            closeSegment(text: text, snapshot: snapshot, language: result.language)
        } else if !text.isEmpty, snapshot.id == latestSnapshotID {
            interimText = text
        }
    }

    private func retryUnresolvedRecognition() async throws {
        guard let snapshot = unresolvedSnapshot else { return }
        guard isReady(.asr) else { throw MinutesError.engineNotReady(worker: "ASR") }
        await gate.acquire()
        let result: EngineClient.ASRResult
        do {
            result = try await transcriber.transcribe(
                snapshot.samples, baseURL: engineSupervisor.configuration.baseURL(for: .asr)
            )
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
        applyRecognitionResult(result, to: snapshot)
        unresolvedSnapshot = nil
        failedSnapshots = [:]
    }

    private func drainRecognitionTasks() async {
        while !recognitionTasks.isEmpty {
            let tasks = Array(recognitionTasks.values)
            for task in tasks { await task.value }
        }
    }

    /// 只落定快照覆盖的前缀；识别期间新到的音频留给下一段。
    private func closeSegment(text: String, snapshot: RecognitionSnapshot, language: String?) {
        interimText = ""
        interimGeneration += 1
        lastPollAt = 0
        if !text.isEmpty {
            appendSegment(TranscriptSegment(
                start: snapshot.start, end: snapshot.end, text: text,
                language: language, sequence: 0
            ))
        }
        let consumed = min(snapshot.samples.count, buffer.count)
        buffer.removeFirst(consumed)
        bufferStart = snapshot.end
        if buffer.isEmpty { bufferEnd = snapshot.end }
        saveDraft()
    }

    /// 会议结束时冲刷缓冲里的剩余音频；失败时保留音频供结束事务重试。
    private func flushBuffer() async throws {
        guard !buffer.isEmpty else { return }
        interimGeneration += 1
        guard isReady(.asr) else { throw MinutesError.engineNotReady(worker: "ASR") }
        let samples = buffer
        let start = bufferStart
        let end = bufferEnd
        await gate.acquire()
        let result: EngineClient.ASRResult
        do {
            result = try await transcriber.transcribe(
                samples, baseURL: engineSupervisor.configuration.baseURL(for: .asr)
            )
        } catch {
            await gate.release()
            Log.error("冲刷识别失败：\(error.localizedDescription)")
            throw error
        }
        await gate.release()
        guard !isDiscarding, !Task.isCancelled else { throw CancellationError() }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            appendSegment(TranscriptSegment(
                start: start, end: end, text: text,
                language: result.language, sequence: 0
            ))
        }
        buffer = []
        bufferStart = end
        bufferEnd = end
        lastPollAt = 0
        interimText = ""
        unresolvedSnapshot = nil
        failedSnapshots = [:]
        saveDraft()
    }

    /// 诊断：UserDefaults `debugCapture` 打开时把采集的原始 PCM 落盘，
    /// 用于区分「麦克风没声」与「识别没触发」。默认关闭，正常路径零开销。
    private var debugFile: FileHandle?

    init(
        store: MeetingsStore,
        engineSupervisor: EngineSupervisor = .shared,
        capture: any MeetingAudioCapturing = AudioCaptureService(),
        transcriber: any MeetingTranscribing = EngineClient.shared,
        chat: any MeetingChatStreaming = EngineClient.shared,
        readiness: ((EngineWorkerKind) -> Bool)? = nil,
        now: @escaping () -> Date = Date.init,
        titleTimeout: TimeInterval = 2,
        draftInterval: TimeInterval = 15
    ) {
        self.store = store
        self.drafts = MeetingDraftStore(directory: store.directory)
        self.engineSupervisor = engineSupervisor
        self.capture = capture
        self.transcriber = transcriber
        self.chat = chat
        self.readiness = readiness
        self.now = now
        self.titleTimeout = titleTimeout
        self.draftInterval = draftInterval
        // 每次新建会议必须生成新的 Meeting（新 id）。
        // 曾共用 store.draft 的副本，所有新会议 id 相同，后一个会把前一个
        // 在列表和磁盘上整体覆盖——「新建会议把上一个会议整没了」的元凶。
        self.meeting = Meeting(title: "")
    }

    /// 从中断会议恢复（ADR-0002）：修复 WAV 头部，按草稿恢复正式片段与时长，
    /// 从已落定位置读入未识别尾部重建缓冲；恢复到暂停态，由用户显式继续。
    convenience init(
        restoring draft: MeetingDraft,
        store: MeetingsStore,
        engineSupervisor: EngineSupervisor = .shared,
        capture: any MeetingAudioCapturing = AudioCaptureService(),
        transcriber: any MeetingTranscribing = EngineClient.shared,
        chat: any MeetingChatStreaming = EngineClient.shared,
        readiness: ((EngineWorkerKind) -> Bool)? = nil,
        now: @escaping () -> Date = Date.init,
        titleTimeout: TimeInterval = 2,
        draftInterval: TimeInterval = 15
    ) throws {
        let audioURL = store.directory.appendingPathComponent("\(draft.meeting.id.uuidString).wav")
        try MeetingAudioFile.repair(at: audioURL)
        let samples = try MeetingAudioFile.readSamples(at: audioURL)
        self.init(
            store: store, engineSupervisor: engineSupervisor, capture: capture,
            transcriber: transcriber, chat: chat, readiness: readiness,
            now: now, titleTimeout: titleTimeout, draftInterval: draftInterval
        )
        meeting = draft.meeting
        phase = .paused
        hasStarted = true
        recordedSampleCount = samples.count
        let tailStart = min(draft.bufferStartSample, samples.count)
        buffer = Array(samples[tailStart...])
        bufferStart = Double(tailStart) / 16_000
        bufferEnd = Double(samples.count) / 16_000
        elapsed = meeting.duration
    }

    var isLive: Bool { phase == .live }

    private func isReady(_ kind: EngineWorkerKind) -> Bool {
        readiness?(kind) ?? (engineSupervisor.states[kind] == .ready)
    }

    private func updateElapsed() {
        guard let recordingStartedAt else { return }
        elapsed = meeting.duration + now().timeIntervalSince(recordingStartedAt)
    }

    // MARK: - 控制

    func start() {
        guard !isDiscarding else { return }
        guard phase == .idle || phase == .paused else { return }
        guard isReady(.asr) else {
            errorMessage = "语音识别引擎未就绪，请先在设置中启动引擎。"
            return
        }
        errorMessage = nil
        phase = .live
        openAudioFileIfNeeded()
        // 有音频即有草稿：首个兜底间隔内的早期崩溃同样可恢复。
        saveDraft()
        startDraftTask()
        if !hasStarted {
            meeting.createdAt = now()
            hasStarted = true
        }
        recordingStartedAt = now()
        elapsed = meeting.duration

        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.recordingStartedAt != nil else { return }
                self.updateElapsed()
            }
        }

        pipelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let stream = try self.capture.start()
                guard !Task.isCancelled, !self.isDiscarding, self.phase == .live else {
                    self.capture.stop()
                    return
                }
                if UserDefaults.standard.bool(forKey: "debugCapture") { self.openDebugFile() }
                for await chunk in stream {
                    if Task.isCancelled { break }
                    let offset = Double(self.recordedSampleCount) / 16_000.0
                    self.recordedSampleCount += chunk.samples.count
                    self.recordAudio(chunk)
                    self.pushEnergy(chunk.rms)
                    if self.debugFile != nil { self.recordDebug(chunk) }
                    self.appendToBuffer(chunk, offset: offset)
                }
            } catch {
                if !Task.isCancelled, !self.isDiscarding {
                    self.errorMessage = error.localizedDescription
                    self.phase = .idle
                }
            }
        }
    }

    func pause() async {
        guard phase == .live, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        updateElapsed()
        phase = .paused
        meeting.duration = elapsed
        recordingStartedAt = nil
        let pipeline = pipelineTask
        pipelineTask = nil
        pipeline?.cancel()
        clockTask?.cancel(); clockTask = nil
        capture.stop()
        closeDebugFile()
        closeAudioFile()
        draftTask?.cancel(); draftTask = nil
        saveDraft()
        await pipeline?.value
        await drainRecognitionTasks()
        if failedSnapshots.values.contains(where: { $0.generation == interimGeneration }), !buffer.isEmpty {
            unresolvedSnapshot = makeSnapshot()
            errorMessage = "部分音频尚未识别，继续时将自动重试。"
        }
    }

    func resume() async {
        guard phase == .paused, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        do {
            try await retryUnresolvedRecognition()
            try Task.checkCancellation()
        } catch {
            if !isDiscarding {
                errorMessage = "识别重试失败：\(error.localizedDescription)"
            }
            return
        }
        guard !isDiscarding, phase == .paused else { return }
        start()
    }

    /// 明确放弃未完成的会议；已保存的历史会议不受影响。
    func discard() async {
        guard phase != .completed else { return }
        isDiscarding = true
        isTransitioning = false
        phase = .idle
        finishStage = nil
        interimGeneration += 1
        recordingStartedAt = nil
        pipelineTask?.cancel()
        clockTask?.cancel()
        finishTask?.cancel()
        for task in recognitionTasks.values { task.cancel() }
        recognitionTasks = [:]
        pipelineTask = nil
        clockTask = nil
        finishTask = nil
        capture.stop()
        closeDebugFile()
        closeAudioFile()
        draftTask?.cancel(); draftTask = nil
        drafts.delete(id: meeting.id)
        if FileManager.default.fileExists(atPath: audioURL.path) {
            do {
                try FileManager.default.removeItem(at: audioURL)
            } catch {
                Log.error("放弃会议清理音频失败：\(error.localizedDescription)")
            }
        }
        buffer = []
        unresolvedSnapshot = nil
        failedSnapshots = [:]
        interimText = ""
        errorMessage = nil
        meeting.segments = []
        meeting.transcriptText = ""
        meeting.minutes = nil
    }

    /// 重复结束调用等待同一事务，不重复识别、生成或保存。
    func finish() async {
        if let finishTask {
            await finishTask.value
            return
        }
        guard phase == .live || phase == .paused || phase == .failed, !isTransitioning else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performFinish()
        }
        finishTask = task
        await task.value
        finishTask = nil
    }

    private func performFinish() async {
        guard phase == .live || phase == .paused || phase == .failed else { return }
        if phase == .live { await pause() }
        guard !isDiscarding, !Task.isCancelled else { return }
        phase = .composing
        errorMessage = nil
        meeting.duration = max(elapsed, meeting.duration)
        do {
            if !transcriptFinalized {
                finishStage = .transcribing
                try await flushBuffer()
                try Task.checkCancellation()
                guard !meeting.segments.isEmpty else {
                    finishStage = nil
                    phase = .paused
                    errorMessage = "没有可生成纪要的内容，请继续录制或放弃会议。"
                    return
                }
                meeting.transcriptText = meeting.segments.map(\.text).joined(separator: "\n")
                transcriptFinalized = true
            }
            if meeting.minutes == nil {
                finishStage = .composing
                try await composeMinutes()
            }
        } catch {
            if isDiscarding { return }
            phase = .failed
            errorMessage = "结束会议失败：\(error.localizedDescription)"
            return
        }
        guard !isDiscarding, !Task.isCancelled else { return }
        // 标题失败不阻塞已经生成的纪要与保存。
        if meeting.title.isEmpty {
            meeting.title = await generateTitle() ?? Self.defaultTitle(for: meeting)
        }
        guard !isDiscarding, !Task.isCancelled else { return }
        finishStage = .saving
        do {
            try store.save(meeting)
        } catch {
            if isDiscarding { return }
            phase = .failed
            errorMessage = "保存会议失败：\(error.localizedDescription)"
            return
        }
        phase = .completed
        finishStage = nil
        drafts.delete(id: meeting.id)
    }

    /// 根据纪要摘要（或转写开头）起一个 ≤15 字的会议标题。
    private func generateTitle() async -> String? {
        guard isReady(.llm) else { return nil }
        let basis = !(meeting.minutes?.summary.isEmpty ?? true)
            ? (meeting.minutes?.summary ?? "")
            : String(meeting.transcriptText.prefix(600))
        guard !basis.isEmpty else { return nil }
        let messages = [
            EngineClient.ChatMessage(role: "system", content: "用不超过15个字概括会议主题，只输出标题本身，不要标点、引号或任何解释。"),
            EngineClient.ChatMessage(role: "user", content: basis),
        ]
        let timeout = titleTimeout
        let raw = await withTaskGroup(of: String?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                do {
                    return try await self.collectChat(messages)
                } catch {
                    Log.info("生成标题失败：\(error.localizedDescription)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let raw else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[\"'「『]+|[\"'」』。．.]+$", with: "", options: .regularExpression)
        guard !title.isEmpty, title.count <= 30 else { return nil }
        return title
    }

    // MARK: - ASR

    /// 中间结果代次：缓冲每次切段/冲刷 +1，防止在飞的过期识别结果
    /// 把已落定的分段覆盖（对齐 qwenasr-studio 的 segGen 设计）。
    private var interimGeneration = 0

    /// 正式片段始终按录制时间轴排序，sequence 与展示顺序一致。
    private func appendSegment(_ segment: TranscriptSegment) {
        meeting.segments.append(segment)
        meeting.segments.sort {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
        for index in meeting.segments.indices {
            meeting.segments[index].sequence = index
        }
    }

    // MARK: - 纪要

    private func composeMinutes() async throws {
        guard isReady(.llm) else {
            throw MinutesError.engineNotReady(worker: "LLM")
        }
        let document = try await MinutesComposer.generate(
            segments: meeting.segments,
            prompt: engineSupervisor.configuration.minutesPrompt,
            baseURL: engineSupervisor.configuration.baseURL(for: .llm),
            chat: chat
        )
        meeting.minutes = document
    }

    /// 起标题旁路调用：收集一次完整对话，不参与纪要工作流。
    private func collectChat(_ messages: [EngineClient.ChatMessage]) async throws -> String {
        var output = ""
        for try await token in await chat.streamChat(
            messages: messages, baseURL: engineSupervisor.configuration.baseURL(for: .llm), temperature: 0.3
        ) {
            try Task.checkCancellation()
            output += token
        }
        try Task.checkCancellation()
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
