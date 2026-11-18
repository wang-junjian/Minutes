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
}
