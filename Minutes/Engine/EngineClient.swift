import Foundation

/// 与本机 audio.cpp / llama.cpp 服务通信的客户端。
actor EngineClient {
    static let shared = EngineClient()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 600
            config.timeoutIntervalForResource = 3600
            self.session = URLSession(configuration: config)
        }
    }

    struct ASRResult: Sendable {
        let text: String
        let language: String?
        let duration: TimeInterval
    }

    // MARK: - ASR

    /// 识别一段 16 kHz 单声道 float32 语音。
    func transcribe(_ samples: [Float], baseURL: URL) async throws -> ASRResult {
        // 与旧服务一致：过短音频不触发模型推理。
        guard samples.count >= WAVEncoder.sampleRate / 2 else {
            return ASRResult(text: "", language: nil, duration: 0)
        }

        let boundary = "Minutes-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.makeASRBody(samples: samples, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else {
            throw MinutesError.decoding("ASR 响应缺少 text 字段")
        }
        return ASRResult(
            text: text,
            language: json["language"] as? String,
            duration: Double(samples.count) / Double(WAVEncoder.sampleRate)
        )
    }

    private static func makeASRBody(samples: [Float], boundary: String) throws -> Data {
        let wav = try WAVEncoder.encode(samples)
        var body = Data()
        body.reserveCapacity(wav.count + 512)

        func append(_ string: String) {
            body.append(contentsOf: Array(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("minutes-asr\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    // MARK: - LLM

    struct ChatMessage: Sendable {
        let role: String
        let content: String
    }

    /// AsyncThrowingStream 在消费者任务取消时可能先正常结束，吞掉生产者随后
    /// 补发的错误。这个薄包装在每次 next() 出口检查取消，保证直接消费者
    /// 也不会把取消后的部分文本当成完整结果。
    struct ChatStream: AsyncSequence, Sendable {
        typealias Element = String

        private let stream: AsyncThrowingStream<String, Error>

        init(_ stream: AsyncThrowingStream<String, Error>) {
            self.stream = stream
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(base: stream.makeAsyncIterator())
        }

        struct Iterator: AsyncIteratorProtocol {
            var base: AsyncThrowingStream<String, Error>.Iterator

            mutating func next() async throws -> String? {
                let element = try await base.next()
                try Task.checkCancellation()
                return element
            }
        }
    }

    /// 流式对话：逐内容块回调，保持对既有会议/纪要调用方的接口不变。
    func streamChat(messages: [ChatMessage], baseURL: URL, temperature: Double = 0.3) -> ChatStream {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": "minutes-llm",
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "max_tokens": 4096,
            "stream": true,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        let data = try await Self.collectErrorBody(bytes)
                        try Self.validate(response, data: data)
                    }
                    try Self.validate(response, data: nil)

                    var parser = OpenAIStreamParser()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for event in try parser.feed(byte) {
                            switch event {
                            case .content(let content):
                                continuation.yield(content)
                            case .done:
                                continuation.finish()
                                return
                            }
                        }
                    }
                    try parser.finish()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return ChatStream(stream)
    }

    // MARK: - Helpers

    private static func collectErrorBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count == 65_536 { break }
        }
        return data
    }

    private static func validate(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MinutesError.network("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            var detail = "HTTP \(http.statusCode)"
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.isEmpty {
                detail += "：\(message)"
            } else if let data,
                      let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !message.isEmpty {
                detail += "：\(message)"
            }
            throw MinutesError.network(detail)
        }
    }
}
