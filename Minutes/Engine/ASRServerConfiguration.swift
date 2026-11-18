import Foundation

/// 根据当前用户配置生成 audio.cpp 服务器配置。
enum ASRServerConfiguration {
    static func write(configuration: EngineConfiguration) throws -> URL {
        let root = URL(fileURLWithPath: (configuration.engineRoot as NSString).expandingTildeInPath)
        let runtimeDirectory = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        let modelPath = (configuration.asrModelPath as NSString).expandingTildeInPath

        let model: [String: Any] = [
            "id": EngineWorkerKind.asr.modelID,
            "family": "qwen3_asr",
            "path": modelPath,
            "task": "asr",
            "mode": "offline",
            "default_request_options": [
                "max_tokens": 512,
                "return_timestamps": false,
                "audio_chunk_mode": "none",
            ],
        ]
        let object: [String: Any] = [
            "host": "127.0.0.1",
            "port": configuration.port(for: .asr),
            "backend": "metal",
            "lazy_load": false,
            "max_loaded_models": 1,
            "log_request_body": false,
            // 60 秒 PCM16 WAV 约 1.9 MiB；为 multipart 留出余量。
            "max_request_body_bytes": 8 * 1_024 * 1_024,
            "models": [model],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let url = runtimeDirectory.appendingPathComponent("asr-\(configuration.port(for: .asr)).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
