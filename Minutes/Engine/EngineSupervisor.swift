import Foundation

/// 管理两个原生推理工作进程。UI 只跟它打交道。
@Observable
@MainActor
final class EngineSupervisor {
    static let shared = EngineSupervisor()

    private(set) var states: [EngineWorkerKind: EngineWorker.State] = [:]
    private(set) var logs: [EngineLogLine] = []
    private var workers: [EngineWorkerKind: EngineWorker] = [:]

    let configuration = EngineConfiguration.shared

    var allReady: Bool {
        EngineWorkerKind.allCases.allSatisfy { states[$0] == .ready }
    }

    private init() {
        for kind in EngineWorkerKind.allCases {
            let worker = EngineWorker(kind: kind, configuration: configuration)
            worker.onStateChange = { [weak self] state in
                Task { @MainActor in
                    self?.states[kind] = state
                }
            }
            worker.onLog = { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(source: kind.rawValue, text: line)
                }
            }
            workers[kind] = worker
            states[kind] = .stopped
        }
    }

    func startAll() {
        for kind in EngineWorkerKind.allCases {
            workers[kind]?.start()
        }
    }

    func stopAll() {
        for kind in EngineWorkerKind.allCases {
            workers[kind]?.stop()
        }
    }

    func start(_ kind: EngineWorkerKind) {
        workers[kind]?.start()
    }

    func stop(_ kind: EngineWorkerKind) {
        workers[kind]?.stop()
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func appendLog(source: String, text: String) {
        logs.append(EngineLogLine(timestamp: Date(), source: source, text: text))
        // 内存中只保留最近 2000 行，避免长跑撑爆。
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }
}
