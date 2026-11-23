import Foundation

/// 将两个上游不同的健康响应归一为应用内部状态。
enum EngineHealth {
    enum Status: Equatable, Sendable {
        case ready(detail: String)
        case starting
        case incompatible(String)
    }

    static func validateLLM(health: [String: Any], props: [String: Any], expectedModelPath: String) -> Status {
        guard health["status"] as? String == "ok",
              let build = props["build_info"] as? String,
              !build.isEmpty
        else {
            return .incompatible("端口上的服务不是受支持的 llama.cpp")
        }
        guard let modelPath = props["model_path"] as? String else {
            return .incompatible("llama.cpp 未返回模型路径")
        }
        guard pathsEqual(modelPath, expectedModelPath) else {
            return .incompatible("llama.cpp 加载的模型与当前设置不一致")
        }
        if props["is_sleeping"] as? Bool == true { return .starting }
        return .ready(detail: "llama.cpp \(build)")
    }

    static func validateASR(health: [String: Any], models: [String: Any], expectedModelPath: String) -> Status {
        guard health["status"] as? String == "ok",
              let version = health["version"] as? String,
              !version.isEmpty,
              health["backend"] as? String == "metal"
        else {
            return .incompatible("端口上的服务不是受支持的 audio.cpp")
        }
        let build = (health["git"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? version
        guard let entries = models["data"] as? [[String: Any]] else {
            return .incompatible("audio.cpp 模型列表格式不受支持")
        }
        guard let model = entries.first(where: { $0["id"] as? String == EngineWorkerKind.asr.modelID }) else {
            return .starting
        }
        guard model["family"] as? String == "qwen3_asr",
              model["configured"] as? Bool == true,
              let modelPath = model["path"] as? String
        else {
            return .incompatible("audio.cpp 模型配置与当前设置不一致")
        }
        guard pathsEqual(modelPath, expectedModelPath) else {
            return .incompatible("audio.cpp 加载的模型与当前设置不一致")
        }
        guard model["loaded"] as? Bool == true else { return .starting }
        return .ready(detail: "audio.cpp \(build)")
    }

    private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        func normalize(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        return normalize(lhs) == normalize(rhs)
    }
}
