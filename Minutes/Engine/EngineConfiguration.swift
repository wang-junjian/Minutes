import Foundation

/// 两个本机原生推理进程的种类。
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

    var executableName: String {
        switch self {
        case .asr: return "audiocpp_server"
        case .llm: return "llama-server"
        }
    }

    var runtimeName: String {
        switch self {
        case .asr: return "audio.cpp"
        case .llm: return "llama.cpp"
        }
    }

    var modelID: String {
        switch self {
        case .asr: return "minutes-asr"
        case .llm: return "minutes-llm"
        }
    }
}

/// 用户可配置项。通过 UserDefaults 持久化。
@Observable
final class EngineConfiguration: @unchecked Sendable {
    // @unchecked 理由：UserDefaults 本身线程安全，此类只做配置读取。
    static let shared = EngineConfiguration()

    private static let currentVersion = 2
    private static let legacyASRPath = "/Users/junjian/GitHub/wang-junjian/qwenasr-studio/models/Qwen3-ASR-1.7B"
    private static let legacyLLMPath = "/Users/junjian/.cache/huggingface/hub/models--mlx-community--Qwen3.5-4B-OptiQ-4bit"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateIfNeeded()
    }

    /// 引擎根目录：包含 bin/ 及原生服务所需运行资源。
    var engineRoot: String {
        get { defaults.string(forKey: "engineRoot") ?? EngineConfiguration.defaultEngineRoot() }
        set { defaults.set(newValue, forKey: "engineRoot") }
    }

    var asrModelPath: String {
        get { defaults.string(forKey: "asrModelPath") ?? Self.defaultASRModelPath() }
        set { defaults.set(newValue, forKey: "asrModelPath") }
    }

    var llmModelPath: String {
        get { defaults.string(forKey: "llmModelPath") ?? Self.defaultLLMModelPath() }
        set { defaults.set(newValue, forKey: "llmModelPath") }
    }

    /// 纪要生成的系统提示词，可在设置中修改；改完用纪要页的「重新生成」生效。
    var minutesPrompt: String {
        get { defaults.string(forKey: "minutesPrompt") ?? MinutesComposer.defaultPrompt }
        set { defaults.set(newValue, forKey: "minutesPrompt") }
    }

    /// 单槽上下文需容纳 12000 字符输入、系统 Prompt 与最多 4096 输出 token。
    let llmContextSize = 32_768

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

    func executableURL(for kind: EngineWorkerKind) -> URL {
        URL(fileURLWithPath: (engineRoot as NSString).expandingTildeInPath)
            .appendingPathComponent("bin/\(kind.executableName)")
    }

    func modelPathError(for kind: EngineWorkerKind) -> String? {
        let path = (modelPath(for: kind) as NSString).expandingTildeInPath
        guard !path.isEmpty else { return "请选择 GGUF 模型文件" }
        guard path.lowercased().hasSuffix(".gguf") else { return "新引擎需要 .gguf 模型文件，旧 HF/MLX 目录不能直接加载" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return "模型文件不存在，请先运行 scripts/download_models.sh 或选择已有 GGUF"
        }
        guard FileManager.default.isReadableFile(atPath: path) else { return "模型文件不可读" }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return "模型文件为空或下载不完整" }
        return nil
    }

    func validationError(for kind: EngineWorkerKind) -> String? {
        let port = port(for: kind)
        guard (1...65_535).contains(port) else { return "端口必须在 1...65535 之间" }
        if let message = modelPathError(for: kind) { return message }
        let executable = executableURL(for: kind).path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return "缺少 \(kind.executableName)，请先运行 scripts/bootstrap.sh"
        }
        return nil
    }

    private func migrateIfNeeded() {
        guard defaults.integer(forKey: "engineConfigurationVersion") < Self.currentVersion else { return }
        let storedASR = defaults.string(forKey: "asrModelPath")
        if storedASR == Self.legacyASRPath {
            defaults.set(Self.defaultASRModelPath(), forKey: "asrModelPath")
        }
        let storedLLM = defaults.string(forKey: "llmModelPath")
        if storedLLM == Self.legacyLLMPath {
            defaults.set(Self.defaultLLMModelPath(), forKey: "llmModelPath")
        }
        defaults.set(Self.currentVersion, forKey: "engineConfigurationVersion")
    }

    static func defaultModelsRoot() -> String {
        if let env = ProcessInfo.processInfo.environment["MINUTES_MODELS_ROOT"] {
            return (env as NSString).expandingTildeInPath
        }
        return applicationSupport().appendingPathComponent("Minutes/models").path
    }

    static func defaultASRModelPath() -> String {
        URL(fileURLWithPath: defaultModelsRoot())
            .appendingPathComponent("Qwen3-ASR-1.7B-GGUF/qwen3-asr-1.7b-q8_0.gguf").path
    }

    static func defaultLLMModelPath() -> String {
        URL(fileURLWithPath: defaultModelsRoot())
            .appendingPathComponent("Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf").path
    }

    private static func defaultEngineRoot() -> String {
        if let env = ProcessInfo.processInfo.environment["MINUTES_ENGINE_ROOT"] {
            return (env as NSString).expandingTildeInPath
        }
        return applicationSupport().appendingPathComponent("Minutes/engine").path
    }

    private static func applicationSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
