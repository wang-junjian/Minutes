import Foundation

/// 与本地推理工作进程通信的流式客户端。
/// 协议细节见 Engine/minutes_engine/ 各 worker 模块。
actor EngineClient {
    static let shared = EngineClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config)
    }

    struct ASRResult: Sendable {
        let text: String
        let language: String?
        let duration: TimeInterval
    }

    // MARK: - ASR

    /// 识别一段 16 kHz 单声道 float32 语音。
    func transcribe(_ samples: [Float], baseURL: URL) async throws -> ASRResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/asr"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = samples.withUnsafeBytes { Data($0) }

        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MinutesError.decoding("ASR 响应不是 JSON")
        }
        return ASRResult(
            text: json["text"] as? String ?? "",
            language: json["language"] as? String,
            duration: json["duration"] as? TimeInterval ?? 0
        )
    }

    // MARK: - LLM

    struct ChatMessage: Sendable {
        let role: String
        let content: String
    }

    /// 流式对话：逐 token 回调，返回完整文本。
    func streamChat(messages: [ChatMessage], baseURL: URL, temperature: Double = 0.3) -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "max_tokens": 4096,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    try validate(response)
                    var full = ""
                    for try await line in bytes.lines {
                        guard !line.isEmpty, let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let token = json["token"] as? String {
                            full += token
                            continuation.yield(token)
                        }
                        if json["done"] as? Bool == true {
                            if let text = json["text"] as? String, !text.isEmpty, text != full {
                                // 某些 worker 只回完整文本不回增量。
                                continuation.yield(text.hasPrefix(full) ? String(text.dropFirst(full.count)) : text)
                            }
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MinutesError.network("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MinutesError.network("HTTP \(http.statusCode)")
        }
    }
}
