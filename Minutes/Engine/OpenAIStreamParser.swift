import Foundation

/// OpenAI Chat Completions 的增量 SSE 解析器。
/// 输入可以是任意网络分片；只有完整事件才按 UTF-8 解码，避免中文被拆坏。
struct OpenAIStreamParser: Sendable {
    enum Event: Equatable, Sendable {
        case content(String)
        case done
    }

    private var line = Data()
    private var dataLines: [String] = []
    private var skipLF = false
    private(set) var isDone = false

    mutating func feed(_ bytes: Data) throws -> [Event] {
        var events: [Event] = []
        for byte in bytes {
            events.append(contentsOf: try feed(byte))
            if isDone { break }
        }
        return events
    }

    mutating func feed(_ byte: UInt8) throws -> [Event] {
        guard !isDone else { return [] }

        switch byte {
        case 0x0D: // CR；后续可选 LF 不再单独成行
            skipLF = true
            return try processLine().map { [$0] } ?? []
        case 0x0A: // LF
            if skipLF {
                skipLF = false
                return []
            }
            return try processLine().map { [$0] } ?? []
        default:
            skipLF = false
            line.append(byte)
            return []
        }
    }

    /// 校验正常结束。容忍最后一个事件省略末尾空行，但不接受静默断流。
    mutating func finish() throws {
        guard !isDone else { return }
        if !line.isEmpty {
            if let event = try processLine(), event == .done { return }
        }
        if !dataLines.isEmpty, let event = try dispatchEvent(), event == .done { return }
        throw MinutesError.decoding("LLM 流在 [DONE] 前结束")
    }

    private mutating func processLine() throws -> Event? {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else {
            return try dispatchEvent()
        }
        guard line.first != 0x3A else { return nil } // ":" 注释 / keep-alive

        let fieldData: Data
        var valueData = Data()
        if let colon = line.firstIndex(of: 0x3A) {
            fieldData = line[..<colon]
            let valueStart = line.index(after: colon)
            valueData = line[valueStart...]
            if valueData.first == 0x20 { valueData.removeFirst() } // 仅移除一个前导空格
        } else {
            fieldData = line
        }
        guard String(decoding: fieldData, as: UTF8.self) == "data" else { return nil }
        dataLines.append(String(decoding: valueData, as: UTF8.self))
        return nil
    }

    private mutating func dispatchEvent() throws -> Event? {
        defer { dataLines.removeAll(keepingCapacity: true) }
        guard !dataLines.isEmpty else { return nil }

        let payload = dataLines.joined(separator: "\n")
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            isDone = true
            return .done
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw MinutesError.decoding("LLM SSE 事件不是合法 JSON")
        }
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "服务器返回未知错误"
            throw MinutesError.network(message)
        }
        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first else {
            return nil // 用量或服务等元数据事件
        }
        if let finishReason = choice["finish_reason"] as? String, finishReason == "length" {
            throw MinutesError.decoding("LLM 输出达到 max_tokens，内容被截断")
        }
        guard let delta = choice["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty
        else { return nil }
        return .content(content)
    }
}
