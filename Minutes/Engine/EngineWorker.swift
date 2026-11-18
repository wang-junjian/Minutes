import Foundation

/// 单个推理工作进程的生命周期管理：拉起、健康检查、日志收集、退出。
/// 进程之间零共享状态，崩溃互不影响，由 Supervisor 决定是否重启。
final class EngineWorker: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    let kind: EngineWorkerKind
    let configuration: EngineConfiguration

    /// 状态变化与日志通过闭包外抛，由 @MainActor 的 Supervisor 收口。
    var onStateChange: (@Sendable (State) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var _state: State = .stopped
    /// 连续自动重启次数：用于指数退避，防止崩溃循环空转。
    private var failureCount = 0

    private(set) var state: State {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set {
            lock.lock(); _state = newValue; lock.unlock()
            onStateChange?(newValue)
        }
    }

    init(kind: EngineWorkerKind, configuration: EngineConfiguration) {
        self.kind = kind
        self.configuration = configuration
    }

    /// 启动前先探测健康端点——可能已有实例在跑，直接复用。
    /// 配置（端口/模型路径）变了会重启进程，不会静默沿用旧配置。
    func start() {
        let signature = launchSignature()
        switch state {
        case .stopped, .failed:
            break
        case .ready, .starting where signature == activeSignature:
            return   // 已就绪且配置未变，幂等
        default:
            stop()
        }
        activeSignature = signature
        state = .starting
        // Task.detached：健康检查内部有信号量等待，绝不能继承调用方的
        // MainActor 上下文——阻塞主线程会冻结 UI，还会搅乱 Swift 并发运行时。
        healthTask = Task.detached { [weak self] in
            guard let self else { return }
            if self.pingHealth() {
                self.failureCount = 0
                self.state = .ready
                return
            }
            self.launch()
            await self.waitUntilHealthyOrExit()
        }
    }

    /// 本次启动依据的配置指纹：端口或模型路径一变，worker 就必须重启。
    private func launchSignature() -> String {
        "\(configuration.port(for: kind))|\(configuration.modelPath(for: kind))"
    }
    private var activeSignature: String?

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        lock.lock()
        let proc = process
        process = nil
        lock.unlock()
        proc?.terminate()
        state = .stopped
    }

    // MARK: - Private

    /// 同步函数：不挂起，避免在异步上下文里碰 NSLock。
    private func launch() {
        let python = configuration.pythonExecutable(for: kind)
        let module = "minutes_engine.\(kind.moduleName)"
        let args = ["-m", module]

        let process = Process()
        process.executableURL = python
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.engineRoot)
        process.environment = Self.environment(for: kind, configuration: configuration)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }

        do {
            try process.run()
        } catch {
            state = .failed("无法启动：\(error.localizedDescription)")
            return
        }

        lock.lock(); self.process = process; lock.unlock()
        pumpLogs(outPipe, tag: "stdout")
        pumpLogs(errPipe, tag: "stderr")
    }

    private func waitUntilHealthyOrExit() async {
        // 最长等待 180 秒（MLX 模型加载、Metal 编译都可能很慢）。
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if Task.isCancelled { return }
            if pingHealth() {
                failureCount = 0
                state = .ready
                return
            }
            // 进程若已退出，terminationHandler 会把状态改成 failed。
            if case .failed = state { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if case .starting = state {
            state = .failed("健康检查超时（180s）")
        }
    }

    private func handleTermination() {
        lock.lock(); process = nil; lock.unlock()
        if case .ready = state {
            state = .failed("进程意外退出，正在自动重启…")
        } else if case .starting = state {
            state = .failed("进程启动即退出，详见日志")
        } else {
            return   // 用户主动停止，不自动拉起
        }
        // 崩溃自愈：推理 worker 可能因系统内存压力等原因意外退出
        // （实测 ASR 1.7B 在重内存压力下会进入 500 僵死态），指数退避后
        // 重新拉起；期间 UI 状态可见。
        failureCount += 1
        let backoffNanos = UInt64(3 * min(1 << failureCount, 16)) * 1_000_000_000
        healthTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: backoffNanos)
            guard let self, !Task.isCancelled else { return }
            self.start()
        }
    }

    private func pingHealth() -> Bool {
        let url = configuration.baseURL(for: kind).appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["status"] as? String == "ok"
            else { return }
            ok = true
        }.resume()
        semaphore.wait()
        return ok
    }

    private func pumpLogs(_ pipe: Pipe, tag: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(omittingEmptySubsequences: false) { $0.isNewline }
            for line in lines where !line.isEmpty {
                self?.onLog?("[\(tag)] \(line)")
            }
        }
    }

    private static func environment(for kind: EngineWorkerKind, configuration: EngineConfiguration) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["MINUTES_WORKER"] = kind.rawValue
        env["MINUTES_PORT"] = String(configuration.port(for: kind))
        env["MINUTES_MODEL_PATH"] = (configuration.modelPath(for: kind) as NSString).expandingTildeInPath
        env["MINUTES_BIND_HOST"] = "127.0.0.1"
        switch kind {
        case .asr:
            break
        case .llm:
            // MLX 引擎铁律：绝不 import transformers，否则启动从 0.7s 变成 60s+。
            env["HF_HUB_OFFLINE"] = "1"
            env["TRANSFORMERS_OFFLINE"] = "1"
        }
        return env
    }
}
