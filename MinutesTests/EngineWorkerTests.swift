import XCTest
@testable import Minutes

final class EngineWorkerTests: XCTestCase {
    func testImmediatelyExitingExecutableFailsWithoutHealthTimeout() async throws {
        let suite = "MinutesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("无法创建测试 defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = NSTemporaryDirectory().appending("MinutesWorkerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let bin = URL(fileURLWithPath: root).appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/false", toPath: bin.appendingPathComponent("audiocpp_server").path)
        let model = URL(fileURLWithPath: root).appendingPathComponent("model.gguf")
        try Data([1]).write(to: model)

        let configuration = EngineConfiguration(defaults: defaults)
        configuration.engineRoot = root
        configuration.asrModelPath = model.path
        configuration.setPort(19_976, for: .asr)
        let worker = EngineWorker(kind: .asr, configuration: configuration)
        defer { worker.stop() }

        let start = Date()
        worker.start()
        var didFail = false
        for _ in 0..<150 {
            if case .failed = worker.state {
                didFail = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(didFail, "立即退出的进程应立即进入 failed，而不是等待健康超时")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testAdoptedExternalServiceMonitorsDisappearanceWithVirtualTime() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueASRReady(configuration: configuration)
        health.enqueueASRReady(configuration: configuration)
        health.enqueueUnavailable("health")
        let launcher = ProcessLauncherStub()
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: launcher, clock: clock
        )
        defer { worker.stop() }

        worker.startForApplicationLaunch()
        let becameReady = await waitUntil { worker.state == .ready }
        XCTAssertTrue(becameReady)
        let monitorIsSleeping = await waitUntil { clock.waiterCount == 1 }
        XCTAssertTrue(monitorIsSleeping)
        XCTAssertEqual(launcher.launchCount, 0)

        clock.advance(by: 5)
        let didFail = await waitUntil { worker.isFailed }
        XCTAssertTrue(didFail)
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testAdoptedExternalServiceMonitorsIdentityChange() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueASRReady(configuration: configuration)
        health.enqueueASRReady(configuration: configuration)
        health.enqueueASRReady(configuration: configuration, modelPath: "/tmp/other.gguf")
        let launcher = ProcessLauncherStub()
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: launcher, clock: clock
        )
        defer { worker.stop() }

        worker.start()
        let becameReady = await waitUntil { worker.state == .ready && clock.waiterCount == 1 }
        XCTAssertTrue(becameReady)
        clock.advance(by: 5)

        let didFail = await waitUntil { worker.isFailed }
        XCTAssertTrue(didFail)
        XCTAssertEqual(launcher.launchCount, 0)
        if case .failed(let message) = worker.state {
            XCTAssertTrue(message.contains("已变化"))
        }
    }

    func testIncompatibleExternalServiceFailsWithoutLaunchingProcess() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueASRReady(configuration: configuration, backend: "cpu")
        let launcher = ProcessLauncherStub()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: launcher, clock: TestEngineClock()
        )
        defer { worker.stop() }

        worker.start()
        let didFail = await waitUntil { worker.isFailed }
        XCTAssertTrue(didFail)
        XCTAssertEqual(launcher.launchCount, 0)
        if case .failed(let message) = worker.state {
            XCTAssertTrue(message.contains("端口"))
        }
    }

    func testOwnedProcessCrashUsesBackoffAndIgnoresLateCallback() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueUnavailable("health")
        health.enqueueASRReady(configuration: configuration)
        health.enqueueUnavailable("health")
        health.enqueueASRReady(configuration: configuration)
        let launcher = ProcessLauncherStub()
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: launcher, clock: clock
        )
        defer { worker.stop() }

        worker.start()
        let becameReady = await waitUntil { worker.state == .ready && launcher.launchCount == 1 }
        XCTAssertTrue(becameReady)
        XCTAssertEqual(launcher.launches[0].executableURL, configuration.executableURL(for: .asr))
        XCTAssertEqual(launcher.launches[0].arguments.first, "--config")
        let oldProcess = launcher.handles[0]

        oldProcess.crash()
        let crashIsWaiting = await waitUntil { worker.isFailed && clock.sleepDurations == [6] }
        XCTAssertTrue(crashIsWaiting)
        clock.advance(by: 5)
        await Task.yield()
        XCTAssertEqual(launcher.launchCount, 1)

        clock.advance(by: 1)
        let restarted = await waitUntil { worker.state == .ready && launcher.launchCount == 2 }
        XCTAssertTrue(restarted)

        oldProcess.fireLateTermination()
        await Task.yield()
        XCTAssertEqual(worker.state, .ready)
    }

    func testImmediatelyExitingStubProcessDoesNotEnterCrashBackoff() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueUnavailable("health")
        let launcher = ProcessLauncherStub(startsRunning: false)
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: launcher, clock: clock
        )
        defer { worker.stop() }

        worker.start()
        let didFail = await waitUntil { worker.isFailed && launcher.launchCount == 1 }
        XCTAssertTrue(didFail)
        clock.advance(by: 60)
        await Task.yield()
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertFalse(clock.sleepDurations.contains(6))
    }

    func testHealthTimeoutTerminatesOwnedProcess() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueUnavailable("health")
        let launcher = ProcessLauncherStub()
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: launcher, clock: clock
        )
        defer { worker.stop() }

        worker.start()
        let launchCompleted = await waitUntil { launcher.launchCount == 1 && clock.waiterCount == 1 }
        XCTAssertTrue(launchCompleted)
        clock.advance(by: 179)
        let lastPollStarted = await waitUntil { clock.now.timeIntervalSince1970 == 179 && clock.waiterCount == 1 }
        XCTAssertTrue(lastPollStarted)
        clock.advance(by: 1)

        let didTimeOut = await waitUntil { worker.isFailed }
        XCTAssertTrue(didTimeOut)
        XCTAssertEqual(launcher.handles[0].terminateCount, 1)
        if case .failed(let message) = worker.state {
            XCTAssertTrue(message.contains("180s"))
        }
    }

    func testStoppedWorkerIgnoresLateHealthResponse() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueASRReady(configuration: configuration, gateHealth: true)
        let launcher = ProcessLauncherStub()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: launcher, clock: TestEngineClock()
        )
        defer { worker.stop() }

        worker.start()
        let healthIsPending = await waitUntil { health.pendingGateCount(for: "health") == 1 }
        XCTAssertTrue(healthIsPending)
        worker.stop()
        health.releaseGate(for: "health")
        let probeFinished = await waitUntil { health.completedRequestCount(for: "health") == 1 }
        XCTAssertTrue(probeFinished)
        await Task.yield()
        XCTAssertEqual(worker.state, .stopped)
        XCTAssertEqual(health.requestCount(for: "v1/models"), 0)
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testApplicationLaunchRetriesFailureOnlyOnceAfterThreeSeconds() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueHTTP("health", status: 500)
        health.enqueueHTTP("health", status: 500)
        let launcher = ProcessLauncherStub()
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: launcher, clock: clock
        )
        defer { worker.stop() }

        worker.startForApplicationLaunch()
        let recoveryIsWaiting = await waitUntil { worker.isFailed && clock.sleepDurations == [3] }
        XCTAssertTrue(recoveryIsWaiting)
        clock.advance(by: 2.9)
        await Task.yield()
        XCTAssertEqual(health.requestCount(for: "health"), 1)

        clock.advance(by: 0.1)
        let retried = await waitUntil { health.requestCount(for: "health") == 2 && worker.isFailed }
        XCTAssertTrue(retried)
        clock.advance(by: 60)
        await Task.yield()
        XCTAssertEqual(health.requestCount(for: "health"), 2)
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testManualStartDoesNotScheduleApplicationRecovery() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueHTTP("health", status: 500)
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: ProcessLauncherStub(), clock: clock
        )
        defer { worker.stop() }

        worker.start()
        let didFail = await waitUntil { worker.isFailed }
        XCTAssertTrue(didFail)
        clock.advance(by: 60)
        await Task.yield()
        XCTAssertEqual(health.requestCount(for: "health"), 1)
        XCTAssertTrue(clock.sleepDurations.isEmpty)
    }

    func testManualStartSupersedesPendingApplicationRecovery() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueHTTP("health", status: 500)
        health.enqueueHTTP("health", status: 500)
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: ProcessLauncherStub(), clock: clock
        )
        defer { worker.stop() }

        worker.startForApplicationLaunch()
        let recoveryIsWaiting = await waitUntil { worker.isFailed && clock.waiterCount == 1 }
        XCTAssertTrue(recoveryIsWaiting)
        worker.start()
        let manualStartFailed = await waitUntil { health.requestCount(for: "health") == 2 && worker.isFailed }
        XCTAssertTrue(manualStartFailed)

        clock.advance(by: 3)
        await Task.yield()
        XCTAssertEqual(health.requestCount(for: "health"), 2)
    }

    func testStopCancelsPendingApplicationRecovery() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueHTTP("health", status: 500)
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: ProcessLauncherStub(), clock: clock
        )
        defer { worker.stop() }

        worker.startForApplicationLaunch()
        let recoveryIsWaiting = await waitUntil { worker.isFailed && clock.waiterCount == 1 }
        XCTAssertTrue(recoveryIsWaiting)
        worker.stop()
        clock.advance(by: 3)
        await Task.yield()

        XCTAssertEqual(worker.state, .stopped)
        XCTAssertEqual(health.requestCount(for: "health"), 1)
    }

    func testConfigurationChangeInvalidatesPendingApplicationRecovery() async throws {
        let configuration = try makeConfiguration()
        let health = HealthTransportStub()
        health.enqueueHTTP("health", status: 500)
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: ProcessLauncherStub(), clock: clock
        )
        defer { worker.stop() }

        worker.startForApplicationLaunch()
        let recoveryIsWaiting = await waitUntil { worker.isFailed && clock.waiterCount == 1 }
        XCTAssertTrue(recoveryIsWaiting)
        configuration.setPort(configuration.port(for: .asr) + 1, for: .asr)
        clock.advance(by: 3)
        await Task.yield()

        XCTAssertEqual(health.requestCount(for: "health"), 1)
        XCTAssertTrue(worker.isFailed)
    }

    func testInvalidConfigurationDoesNotScheduleApplicationRecovery() async throws {
        let configuration = try makeConfiguration()
        configuration.asrModelPath = configuration.asrModelPath + ".missing"
        let health = HealthTransportStub()
        let clock = TestEngineClock()
        let worker = EngineWorker(
            kind: .asr, configuration: configuration,
            healthTransport: health, processLauncher: ProcessLauncherStub(), clock: clock
        )
        defer { worker.stop() }

        worker.startForApplicationLaunch()
        XCTAssertTrue(worker.isFailed)
        clock.advance(by: 3)
        await Task.yield()
        XCTAssertEqual(health.totalRequestCount, 0)
        XCTAssertTrue(clock.sleepDurations.isEmpty)
    }

    private func makeConfiguration() throws -> EngineConfiguration {
        let suite = "MinutesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw StubError.defaults }
        addTeardownBlock {
            if let defaults = UserDefaults(suiteName: suite) {
                defaults.removePersistentDomain(forName: suite)
            }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinutesWorkerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/false"),
            to: bin.appendingPathComponent("audiocpp_server")
        )
        let model = root.appendingPathComponent("model.gguf")
        try Data([1]).write(to: model)

        let configuration = EngineConfiguration(defaults: defaults)
        configuration.engineRoot = root.path
        configuration.asrModelPath = model.path
        configuration.setPort(Int.random(in: 20_000..<40_000), for: .asr)
        return configuration
    }
}

private enum StubError: Error {
    case defaults
}

private extension EngineWorker {
    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

private final class HealthTransportStub: EngineHealthTransport, @unchecked Sendable {
    private struct Reply {
        let status: Int?
        let data: Data?
        let gated: Bool
    }

    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var requests: [String: Int] = [:]
    private var completedRequests: [String: Int] = [:]

    var totalRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.values.reduce(0, +)
    }

    func requestCount(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests[path, default: 0]
    }

    func pendingGateCount(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return gates[path, default: []].count
    }

    func completedRequestCount(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return completedRequests[path, default: 0]
    }

    func enqueueUnavailable(_ path: String, gated: Bool = false) {
        enqueue(path, Reply(status: nil, data: nil, gated: gated))
    }

    func enqueueHTTP(_ path: String, status: Int = 200, object: [String: Any]? = nil, gated: Bool = false) {
        let data = object.map { try! JSONSerialization.data(withJSONObject: $0) }
        enqueue(path, Reply(status: status, data: data, gated: gated))
    }

    func enqueueASRReady(
        configuration: EngineConfiguration,
        backend: String = "metal",
        modelPath: String? = nil,
        gateHealth: Bool = false
    ) {
        enqueueHTTP("health", object: [
            "status": "ok", "backend": backend, "version": "test", "git": "worker-test",
        ], gated: gateHealth)
        enqueueHTTP("v1/models", object: ["data": [[
            "id": EngineWorkerKind.asr.modelID,
            "family": "qwen3_asr",
            "configured": true,
            "loaded": true,
            "path": modelPath ?? configuration.asrModelPath,
        ]]])
    }

    func releaseGate(for path: String) {
        lock.lock()
        let continuations = gates.removeValue(forKey: path) ?? []
        lock.unlock()
        for continuation in continuations { continuation.resume() }
    }

    func send(_ request: URLRequest) async -> (data: Data?, response: HTTPURLResponse?) {
        let path = request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let reply = takeReply(for: path)

        if reply.gated {
            await withCheckedContinuation { continuation in
                addGate(continuation, for: path)
            }
        }
        guard let status = reply.status, let url = request.url else {
            complete(path)
            return (nil, nil)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        complete(path)
        return (reply.data, response)
    }

    private func takeReply(for path: String) -> Reply {
        lock.lock(); defer { lock.unlock() }
        requests[path, default: 0] += 1
        guard replies[path]?.isEmpty == false else {
            return Reply(status: nil, data: nil, gated: false)
        }
        return replies[path]!.removeFirst()
    }

    private func addGate(_ continuation: CheckedContinuation<Void, Never>, for path: String) {
        lock.lock()
        gates[path, default: []].append(continuation)
        lock.unlock()
    }

    private func complete(_ path: String) {
        lock.lock()
        completedRequests[path, default: 0] += 1
        lock.unlock()
    }

    private func enqueue(_ path: String, _ reply: Reply) {
        lock.lock()
        replies[path, default: []].append(reply)
        lock.unlock()
    }
}

private final class ProcessLauncherStub: EngineProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let startsRunning: Bool
    private var _launches: [EngineProcessLaunch] = []
    private var _handles: [ProcessHandleStub] = []

    init(startsRunning: Bool = true) {
        self.startsRunning = startsRunning
    }

    var launchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _launches.count
    }

    var launches: [EngineProcessLaunch] {
        lock.lock(); defer { lock.unlock() }
        return _launches
    }

    var handles: [ProcessHandleStub] {
        lock.lock(); defer { lock.unlock() }
        return _handles
    }

    func launch(
        _ launch: EngineProcessLaunch,
        onLog: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (any EngineProcessHandle) -> Void
    ) throws -> any EngineProcessHandle {
        let handle = ProcessHandleStub(isRunning: startsRunning, onTermination: onTermination)
        lock.lock()
        _launches.append(launch)
        _handles.append(handle)
        lock.unlock()
        return handle
    }
}

private final class ProcessHandleStub: EngineProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private var _terminateCount = 0
    private let onTermination: @Sendable (any EngineProcessHandle) -> Void

    init(isRunning: Bool, onTermination: @escaping @Sendable (any EngineProcessHandle) -> Void) {
        self.running = isRunning
        self.onTermination = onTermination
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var terminateCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _terminateCount
    }

    func terminate() {
        lock.lock()
        running = false
        _terminateCount += 1
        lock.unlock()
        onTermination(self)
    }

    func crash() {
        lock.lock()
        running = false
        lock.unlock()
        onTermination(self)
    }

    func fireLateTermination() {
        onTermination(self)
    }
}

private final class TestEngineClock: EngineClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var waiters: [UUID: Waiter] = [:]
    private var _sleepDurations: [TimeInterval] = []

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return Date(timeIntervalSince1970: current)
    }

    var waiterCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }

    var sleepDurations: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return _sleepDurations
    }

    func sleep(for seconds: TimeInterval) async throws {
        if seconds <= 0 {
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                _sleepDurations.append(seconds)
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(deadline: current + seconds, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current += interval
        let due = waiters.filter { $0.value.deadline <= current }
        for id in due.keys { waiters.removeValue(forKey: id) }
        lock.unlock()
        for waiter in due.values.sorted(by: { $0.deadline < $1.deadline }) {
            waiter.continuation.resume()
        }
    }
}
