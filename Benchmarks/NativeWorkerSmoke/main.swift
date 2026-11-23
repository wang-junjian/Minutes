import Foundation

@main
struct NativeWorkerSmoke {
    static func main() async throws {
        let configuration = EngineConfiguration()
        let asr = EngineWorker(kind: .asr, configuration: configuration)
        let llm = EngineWorker(kind: .llm, configuration: configuration)
        asr.onStateChange = { print("ASR state=\($0)") }
        llm.onStateChange = { print("LLM state=\($0)") }
        asr.onLog = { print("ASR \($0)") }
        llm.onLog = { print("LLM \($0)") }
        defer { asr.stop(); llm.stop() }

        asr.start()
        llm.start()
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if case .failed(let message) = asr.state {
                throw MinutesError.network("ASR worker: \(message)")
            }
            if case .failed(let message) = llm.state {
                throw MinutesError.network("LLM worker: \(message)")
            }
            if asr.state == .ready, llm.state == .ready {
                print("Both native workers are ready")
                let environment = ProcessInfo.processInfo.environment
                if let path = environment["MINUTES_SMOKE_ASR"] {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let samples = data.withUnsafeBytes { bytes in
                        Array(bytes.bindMemory(to: Float.self))
                    }
                    let result = try await EngineClient.shared.transcribe(
                        samples,
                        baseURL: URL(string: "http://127.0.0.1:8797")!
                    )
                    print("ASR duration=\(result.duration) text=\(result.text)")
                    guard result.text.contains("虚拟电厂") else {
                        throw MinutesError.decoding("真实 ASR 未返回预期会议关键词")
                    }
                }
                if environment["MINUTES_SMOKE_LLM"] == "1" {
                    let messages = [
                        EngineClient.ChatMessage(role: "system", content: "你是会议记录员，只输出 ## 摘要 和 ## 行动项 两节。"),
                        EngineClient.ChatMessage(role: "user", content: "会议决定周五上线，张三负责验证。"),
                    ]
                    var output = ""
                    for try await chunk in await EngineClient.shared.streamChat(
                        messages: messages,
                        baseURL: URL(string: "http://127.0.0.1:8788")!
                    ) {
                        output += chunk
                    }
                    print("LLM output:\n\(output)")
                    guard output.contains("## 摘要"), output.contains("## 行动项"), !output.contains("<think>") else {
                        throw MinutesError.decoding("真实 LLM 输出格式不符合要求")
                    }
                }
                if environment["MINUTES_SMOKE_MAP_REDUCE"] == "1" {
                    let line = "园区确认虚拟电厂一期下周三上线，张三负责数据接入，李四负责告警规则，王五记录压力测试问题。\n"
                    let transcript = String(repeating: line, count: 700)
                    let document = await MinutesComposer.generate(
                        transcript: transcript,
                        prompt: MinutesComposer.defaultPrompt,
                        baseURL: URL(string: "http://127.0.0.1:8788")!,
                        onProgress: { print("Map-reduce: \($0)") }
                    )
                    guard let document, !document.summary.isEmpty else {
                        throw MinutesError.decoding("长文本 map-reduce 未生成有效纪要")
                    }
                    print("Map-reduce summary=\(document.summary)")
                }
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw MinutesError.network("原生 worker 90 秒内未就绪")
    }
}
