import Foundation

protocol EngineHealthTransport: Sendable {
    func send(_ request: URLRequest) async -> (data: Data?, response: HTTPURLResponse?)
}

struct URLSessionEngineHealthTransport: EngineHealthTransport {
    func send(_ request: URLRequest) async -> (data: Data?, response: HTTPURLResponse?) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as? HTTPURLResponse)
        } catch {
            return (nil, nil)
        }
    }
}

protocol EngineClock: Sendable {
    var now: Date { get }
    func sleep(for seconds: TimeInterval) async throws
}

struct SystemEngineClock: EngineClock {
    var now: Date { Date() }

    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

struct EngineProcessLaunch: Sendable {
    let executableURL: URL
    let currentDirectoryURL: URL
    let arguments: [String]
    let environment: [String: String]
}

protocol EngineProcessHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
}

protocol EngineProcessLaunching: Sendable {
    func launch(
        _ launch: EngineProcessLaunch,
        onLog: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (any EngineProcessHandle) -> Void
    ) throws -> any EngineProcessHandle
}

private final class NativeEngineProcessHandle: EngineProcessHandle, @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }
    func terminate() { process.terminate() }
}

struct NativeEngineProcessLauncher: EngineProcessLaunching {
    func launch(
        _ launch: EngineProcessLaunch,
        onLog: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (any EngineProcessHandle) -> Void
    ) throws -> any EngineProcessHandle {
        let process = Process()
        process.executableURL = launch.executableURL
        process.currentDirectoryURL = launch.currentDirectoryURL
        process.arguments = launch.arguments
        process.environment = launch.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let handle = NativeEngineProcessHandle(process: process)
        process.terminationHandler = { [weak handle] _ in
            guard let handle else { return }
            onTermination(handle)
        }

        try process.run()
        pumpLogs(outPipe, tag: "stdout", onLog: onLog)
        pumpLogs(errPipe, tag: "stderr", onLog: onLog)
        return handle
    }

    private func pumpLogs(_ pipe: Pipe, tag: String, onLog: @escaping @Sendable (String) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(omittingEmptySubsequences: false) { $0.isNewline }
            for line in lines where !line.isEmpty {
                onLog("[\(tag)] \(line)")
            }
        }
    }
}

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

    private enum StartRecovery {
        case none
        case applicationLaunch
    }

    let kind: EngineWorkerKind
    let configuration: EngineConfiguration

    var onStateChange: (@Sendable (State) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    private let healthTransport: any EngineHealthTransport
    private let processLauncher: any EngineProcessLaunching
    private let clock: any EngineClock
    private let lock = NSLock()
    private var process: (any EngineProcessHandle)?
    private var healthTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
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

    init(
        kind: EngineWorkerKind,
        configuration: EngineConfiguration,
        healthTransport: any EngineHealthTransport = URLSessionEngineHealthTransport(),
        processLauncher: any EngineProcessLaunching = NativeEngineProcessLauncher(),
        clock: any EngineClock = SystemEngineClock()
    ) {
        self.kind = kind
        self.configuration = configuration
        self.healthTransport = healthTransport
        self.processLauncher = processLauncher
        self.clock = clock
    }

    func start() {
        cancelRecovery()
        start(recovery: .none)
    }

    /// 应用启动专属：旧实例进程可能仍在退出，允许一次三秒后的失败恢复。
    func startForApplicationLaunch() {
        cancelRecovery()
        start(recovery: .applicationLaunch)
    }

    private func start(recovery: StartRecovery) {
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
        // 健康探测和进程回调不能继承 MainActor。
        healthTask = Task.detached { [weak self] in
            guard let self else { return }
            let probe = await self.probeHealth()
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
        if recovery == .applicationLaunch {
            recoveryTask = Task.detached { [weak self] in
                guard let self else { return }
                do {
                    try await self.clock.sleep(for: 3)
                } catch {
                    return
                }
                guard self.isFailed(signature) else { return }
                self.recoveryTask = nil
                self.start()
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
        cancelRecovery()
        healthTask?.cancel()
        healthTask = nil
        lock.lock()
        let proc = process
        process = nil
        lock.unlock()
        state = .stopped
        proc?.terminate()
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    // MARK: - Launch

    private func launch(signature: String) {
        guard isStarting(signature) else { return }

        let arguments: [String]
        do {
            switch kind {
            case .asr:
                let configURL = try ASRServerConfiguration.write(configuration: configuration)
                arguments = ["--config", configURL.path]
            case .llm:
                let model = (configuration.llmModelPath as NSString).expandingTildeInPath
                arguments = [
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
        let description = EngineProcessLaunch(
            executableURL: configuration.executableURL(for: kind),
            currentDirectoryURL: URL(fileURLWithPath: (configuration.engineRoot as NSString).expandingTildeInPath),
            arguments: arguments,
            environment: environment
        )

        let launched: any EngineProcessHandle
        do {
            launched = try processLauncher.launch(
                description,
                onLog: { [weak self] line in self?.onLog?(line) },
                onTermination: { [weak self] terminated in
                    self?.handleTermination(terminated)
                }
            )
        } catch {
            failIfStarting("无法启动 \(kind.executableName)：\(error.localizedDescription)", signature: signature)
            return
        }

        // 先登记，再检查 isRunning：即使回调先于登记执行，也能由这次检查补回。
        lock.lock()
        let shouldContinue = _state == .starting && activeSignature == signature && !Task.isCancelled && self.process == nil
        if shouldContinue { self.process = launched }
        lock.unlock()
        guard shouldContinue else {
            launched.terminate()
            return
        }

        if !launched.isRunning { handleTermination(launched) }
    }

    private func waitUntilHealthyOrExit(expectsOwnedProcess: Bool, signature: String) async {
        let deadline = clock.now.addingTimeInterval(180)
        while clock.now < deadline {
            guard isStarting(signature) else { return }
            let probe = await probeHealth()
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
            do {
                try await clock.sleep(for: 1)
            } catch {
                return
            }
        }
        failIfStarting("健康检查超时（180s），详见引擎日志", signature: signature)
        terminateOwnedProcess()
    }

    /// 外部启动的服务没有 Process 终止回调，ready 后继续监测其存活与身份。
    private func monitorExternalHealth(_ signature: String) async {
        while isReady(signature) {
            if hasOwnedProcess() { return }
            let probe = await probeHealth()
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
            do {
                try await clock.sleep(for: 5)
            } catch {
                return
            }
        }
    }

    private func terminateOwnedProcess() {
        lock.lock()
        let proc = process
        process = nil
        lock.unlock()
        proc?.terminate()
    }

    private func handleTermination(_ terminated: any EngineProcessHandle) {
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
        let backoff = TimeInterval(3 * min(1 << min(failureCount, 4), 16))
        healthTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: backoff)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
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

    private func isFailed(_ signature: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !Task.isCancelled, activeSignature == signature, launchSignature() == signature else { return false }
        if case .failed = _state { return true }
        return false
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
        cancelRecovery()
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

    private func probeHealth() async -> ProbeResult {
        let health = await fetch("health")
        guard !Task.isCancelled else { return .unavailable }
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
            let props = await fetch("props")
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
            let models = await fetch("v1/models")
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

    private func fetch(_ path: String) async -> (data: Data?, response: HTTPURLResponse?) {
        let url = configuration.baseURL(for: kind).appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        return await healthTransport.send(request)
    }
}
