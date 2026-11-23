import Foundation

/// 单个原生推理进程的生命周期管理：拉起、身份/健康检查、日志收集、退出。
final class EngineWorker: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    private enum ProbeResult {
        case unavailable
        case starting
        case ready(detail: String)
        case incompatible(String)
    }

    let kind: EngineWorkerKind
    let configuration: EngineConfiguration

    var onStateChange: (@Sendable (State) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var _state: State = .stopped
    private var failureCount = 0
    private var activeSignature: String?

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

    func start() {
        let signature = launchSignature()
        switch state {
        case .stopped, .failed:
            break
        case .ready where signature == activeSignature,
             .starting where signature == activeSignature:
            return
        default:
            stop()
        }
        activeSignature = signature
        if let error = configuration.validationError(for: kind) {
            state = .failed(error)
            return
        }

        state = .starting
        // 健康探测内部有信号量等待，不能继承 MainActor。
        healthTask = Task.detached { [weak self] in
            guard let self else { return }
            let probe = self.probeHealth()
            guard self.isStarting(signature) else { return }
            switch probe {
            case .ready(let detail):
                if self.becomeReady(detail: detail, signature: signature) {
                    await self.monitorExternalHealth(signature)
                }
            case .starting:
                await self.waitUntilHealthyOrExit(expectsOwnedProcess: false, signature: signature)
            case .incompatible(let message):
                self.failIfStarting(
                    "端口 \(self.configuration.port(for: self.kind)) 被占用：\(message)。请停止旧服务或修改端口",
                    signature: signature
                )
            case .unavailable:
                self.launch(signature: signature)
                if case .failed = self.state { return }
                await self.waitUntilHealthyOrExit(expectsOwnedProcess: true, signature: signature)
            }
        }
    }

    /// 端口、模型、可执行文件或关键启动参数变化都必须重新启动。
    private func launchSignature() -> String {
        [
            configuration.engineRoot,
            configuration.modelPath(for: kind),
            String(configuration.port(for: kind)),
            kind == .llm ? String(configuration.llmContextSize) : "offline",
        ].joined(separator: "|")
    }

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        lock.lock()
        let proc = process
        process = nil
        lock.unlock()
        state = .stopped
        proc?.terminate()
    }

    // MARK: - Launch

    private func launch(signature: String) {
        guard isStarting(signature) else { return }

        let process = Process()
        process.executableURL = configuration.executableURL(for: kind)
        process.currentDirectoryURL = URL(fileURLWithPath: (configuration.engineRoot as NSString).expandingTildeInPath)

        do {
            switch kind {
            case .asr:
                let configURL = try ASRServerConfiguration.write(configuration: configuration)
                process.arguments = ["--config", configURL.path]
            case .llm:
                let model = (configuration.llmModelPath as NSString).expandingTildeInPath
                process.arguments = [
                    "--model", model,
                    "--alias", kind.modelID,
                    "--host", "127.0.0.1",
                    "--port", String(configuration.port(for: kind)),
                    "--ctx-size", String(configuration.llmContextSize),
                    "--parallel", "1",
                    "--gpu-layers", "all",
                    "--reasoning", "off",
                ]
            }
        } catch {
            failIfStarting("无法生成原生服务配置：\(error.localizedDescription)", signature: signature)
            return
        }

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DYLD_LIBRARY_PATH")
        environment.removeValue(forKey: "DYLD_FALLBACK_LIBRARY_PATH")
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.terminationHandler = { [weak self] terminated in
            self?.handleTermination(terminated)
        }

        guard isStarting(signature) else { return }
        do {
            try process.run()
        } catch {
            failIfStarting("无法启动 \(kind.executableName)：\(error.localizedDescription)", signature: signature)
            return
        }

        // 先登记，再检查 isRunning：即使回调先于登记执行，也能由这次检查补回。
        lock.lock()
        let shouldContinue = _state == .starting && activeSignature == signature && !Task.isCancelled && self.process == nil
        if shouldContinue { self.process = process }
        lock.unlock()
        guard shouldContinue else {
            process.terminate()
            return
        }

        pumpLogs(outPipe, tag: "stdout")
        pumpLogs(errPipe, tag: "stderr")
        if !process.isRunning { handleTermination(process) }
    }

    private func waitUntilHealthyOrExit(expectsOwnedProcess: Bool, signature: String) async {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            guard isStarting(signature) else { return }
            let probe = probeHealth()
            guard isStarting(signature) else { return }
            switch probe {
            case .ready(let detail):
                if becomeReady(detail: detail, signature: signature), !expectsOwnedProcess {
                    await monitorExternalHealth(signature)
                }
                return
            case .incompatible(let message):
                failIfStarting("原生服务身份检查失败：\(message)", signature: signature)
                terminateOwnedProcess()
                return
            case .unavailable where !expectsOwnedProcess:
                failIfStarting("已有原生服务在启动过程中退出", signature: signature)
                return
            case .unavailable, .starting:
                break
            }
            if case .failed = state { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        failIfStarting("健康检查超时（180s），详见引擎日志", signature: signature)
        terminateOwnedProcess()
    }

    /// 外部启动的服务没有 Process 终止回调，ready 后继续监测其存活与身份。
    private func monitorExternalHealth(_ signature: String) async {
        while isReady(signature) {
            if hasOwnedProcess() { return }
            let probe = probeHealth()
            if Task.isCancelled || !isReady(signature) { return }
            switch probe {
            case .ready, .starting:
                break
            case .unavailable:
                failIfReady("外部 \(kind.runtimeName) 服务已停止，请重新启动", signature: signature)
                return
            case .incompatible(let message):
                failIfReady("外部 \(kind.runtimeName) 服务已变化：\(message)", signature: signature)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func terminateOwnedProcess() {
        lock.lock()
        let proc = process
        process = nil
        lock.unlock()
        proc?.terminate()
    }

    private func handleTermination(_ terminated: Process) {
        lock.lock()
        guard process === terminated else {
            lock.unlock()
            return
        }
        process = nil
        lock.unlock()

        if case .ready = state {
            state = .failed("\(kind.runtimeName) 意外退出，正在自动重启…")
        } else if case .starting = state {
            // 启动即退出通常是模型、端口或配置错误，先展示日志，不做崩溃循环。
            state = .failed("\(kind.runtimeName) 启动即退出，详见日志")
            return
        } else {
            return
        }

        failureCount += 1
        let backoffNanos = UInt64(3 * min(1 << min(failureCount, 4), 16)) * 1_000_000_000
        healthTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: backoffNanos)
            guard let self, !Task.isCancelled else { return }
            self.start()
        }
    }

    // MARK: - State transitions

    private func isStarting(_ signature: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !Task.isCancelled && _state == .starting && activeSignature == signature
    }

    private func isReady(_ signature: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !Task.isCancelled && _state == .ready && activeSignature == signature
    }

    private func hasOwnedProcess() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return process != nil
    }

    private func becomeReady(detail: String, signature: String) -> Bool {
        lock.lock()
        guard !Task.isCancelled, _state == .starting, activeSignature == signature else {
            lock.unlock()
            return false
        }
        _state = .ready
        failureCount = 0
        lock.unlock()
        onLog?("[health] \(detail)")
        onStateChange?(.ready)
        return true
    }

    private func failIfStarting(_ message: String, signature: String) {
        lock.lock()
        guard !Task.isCancelled, _state == .starting, activeSignature == signature else {
            lock.unlock()
            return
        }
        _state = .failed(message)
        lock.unlock()
        onStateChange?(.failed(message))
    }

    private func failIfReady(_ message: String, signature: String) {
        lock.lock()
        guard !Task.isCancelled, _state == .ready, activeSignature == signature else {
            lock.unlock()
            return
        }
        _state = .failed(message)
        lock.unlock()
        onStateChange?(.failed(message))
    }

    // MARK: - Health

    private func probeHealth() -> ProbeResult {
        let health = fetch("health")
        guard let healthResponse = health.response else { return .unavailable }

        if kind == .llm, healthResponse.statusCode == 503,
           let data = health.data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           (error["message"] as? String)?.localizedCaseInsensitiveContains("loading") == true {
            return .starting
        }
        guard healthResponse.statusCode == 200,
              let healthData = health.data,
              let healthJSON = try? JSONSerialization.jsonObject(with: healthData) as? [String: Any]
        else {
            return .incompatible("健康端点返回 HTTP \(healthResponse.statusCode)")
        }

        switch kind {
        case .llm:
            let props = fetch("props")
            guard props.response?.statusCode == 200,
                  let data = props.data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .incompatible("无法读取 llama.cpp /props") }
            return mapHealth(EngineHealth.validateLLM(
                health: healthJSON,
                props: json,
                expectedModelPath: configuration.llmModelPath
            ))
        case .asr:
            let models = fetch("v1/models")
            guard models.response?.statusCode == 200,
                  let data = models.data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .incompatible("无法读取 audio.cpp /v1/models") }
            return mapHealth(EngineHealth.validateASR(
                health: healthJSON,
                models: json,
                expectedModelPath: configuration.asrModelPath
            ))
        }
    }

    private func mapHealth(_ status: EngineHealth.Status) -> ProbeResult {
        switch status {
        case .ready(let detail): return .ready(detail: detail)
        case .starting: return .starting
        case .incompatible(let message): return .incompatible(message)
        }
    }

    private func fetch(_ path: String) -> (data: Data?, response: HTTPURLResponse?) {
        let url = configuration.baseURL(for: kind).appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let semaphore = DispatchSemaphore(value: 0)
        let result = HealthResponseBox()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result.store(data: data, response: response as? HTTPURLResponse)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result.load()
    }

    // MARK: - Logs

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
}

private final class HealthResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (data: Data?, response: HTTPURLResponse?) = (nil, nil)

    func store(data: Data?, response: HTTPURLResponse?) {
        lock.lock()
        value = (data, response)
        lock.unlock()
    }

    func load() -> (data: Data?, response: HTTPURLResponse?) {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
