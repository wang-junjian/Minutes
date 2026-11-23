import Foundation

/// 三个推理工作进程的种类。每个种类对应一个独立 Python 解释器与端口。
enum EngineWorkerKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case asr
    case llm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .asr: return "语音识别"
        case .llm: return "语言模型"
        }
    }

    var defaultPort: Int {
        switch self {
        case .asr: return 8797   // 8787 常被本机其他 ASR 服务占用，换冷门端口
        case .llm: return 8788
        }
    }

    /// Python 模块入口：`python -m minutes_engine.<module>`
    var moduleName: String { "\(rawValue)_worker" }
}

/// 用户可配置项。通过 UserDefaults 持久化。
@Observable
final class EngineConfiguration: @unchecked Sendable {
    // @unchecked 理由：UserDefaults 本身线程安全，此类只做配置读取。
    static let shared = EngineConfiguration()

    private let defaults = UserDefaults.standard

    /// 引擎根目录：内含 minutes_engine/ 包与 .venvs/ 三个独立环境。
    var engineRoot: String {
        get { defaults.string(forKey: "engineRoot") ?? EngineConfiguration.defaultEngineRoot() }
        set { defaults.set(newValue, forKey: "engineRoot") }
    }

    var asrModelPath: String {
        get { defaults.string(forKey: "asrModelPath") ?? "/Users/junjian/GitHub/wang-junjian/qwenasr-studio/models/Qwen3-ASR-1.7B" }
        set { defaults.set(newValue, forKey: "asrModelPath") }
    }

    /// 支持传 hub 缓存根目录，worker 端会自行解析 snapshots/ 下最新快照。
    var llmModelPath: String {
        get { defaults.string(forKey: "llmModelPath") ?? "/Users/junjian/.cache/huggingface/hub/models--mlx-community--Qwen3.5-4B-OptiQ-4bit" }
        set { defaults.set(newValue, forKey: "llmModelPath") }
    }

    /// 纪要生成的系统提示词，可在设置中修改；改完用纪要页的「重新生成」生效。
    var minutesPrompt: String {
        get {
            defaults.string(forKey: "minutesPrompt") ?? MinutesComposer.defaultPrompt
        }
        set { defaults.set(newValue, forKey: "minutesPrompt") }
    }


    func port(for kind: EngineWorkerKind) -> Int {
        Int(defaults.integer(forKey: "port.\(kind.rawValue)") != 0 ? defaults.integer(forKey: "port.\(kind.rawValue)") : kind.defaultPort)
    }

    func setPort(_ port: Int, for kind: EngineWorkerKind) {
        defaults.set(port, forKey: "port.\(kind.rawValue)")
    }

    func baseURL(for kind: EngineWorkerKind) -> URL {
        URL(string: "http://127.0.0.1:\(port(for: kind))")!
    }

    func modelPath(for kind: EngineWorkerKind) -> String {
        switch kind {
        case .asr: return asrModelPath
        case .llm: return llmModelPath
        }
    }

    /// 某个 worker 的 Python 解释器路径。bootstrap.sh 创建 .venvs/<kind>。
    func pythonExecutable(for kind: EngineWorkerKind) -> URL {
        URL(fileURLWithPath: engineRoot)
            .appendingPathComponent(".venvs/\(kind.rawValue)/bin/python")
    }

    private static func defaultEngineRoot() -> String {
        // 开发期：优先用工程内的 Engine/ 目录（相对 DerivedData 构建产物的稳定查找太脆，
        // 这里显式以环境变量/用户设置为准，缺省指向 Application Support 安装位）。
        if let env = ProcessInfo.processInfo.environment["MINUTES_ENGINE_ROOT"] {
            return (env as NSString).expandingTildeInPath
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Minutes/engine").path
    }
}
