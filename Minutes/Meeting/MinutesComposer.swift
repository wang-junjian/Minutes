import Foundation

protocol MeetingChatStreaming: Sendable {
    func streamChat(
        messages: [EngineClient.ChatMessage], baseURL: URL, temperature: Double
    ) async -> EngineClient.ChatStream
}

extension EngineClient: MeetingChatStreaming {}

/// 纪要生成工作流：统一拥有输入规范化、map-reduce、流聚合、完整性与结构化解析。
enum MinutesComposer {
    enum Stage: Equatable, Sendable {
        case generating
        case mapping(index: Int, total: Int)
        case reducing
    }

    enum GenerationError: LocalizedError, Equatable, Sendable {
        case emptyTranscript
        case invalidDocument(String)

        var errorDescription: String? {
            switch self {
            case .emptyTranscript:
                return "没有可生成纪要的转写内容"
            case .invalidDocument(let reason):
                return "纪要结果不完整：\(reason)"
            }
        }
    }

    /// 默认的系统提示词；用户可在设置中覆盖（EngineConfiguration.minutesPrompt）。
    static let defaultPrompt = """
        你是一位专业的会议记录员。根据用户提供的会议转写，输出结构化纪要。
        严格使用如下 Markdown 结构，不要输出任何其他内容：

        ## 摘要
        （3-6 句话概括会议核心内容）

        ## 决议
        - （会议上达成的一致决定）

        ## 行动项
        - （需要执行的具体事项，含负责人与时间如果转写中有）

        ## 关键词
        （5 个以内，逗号分隔）

        要求：忠实转写内容，不编造转写中没有的信息；使用与转写相同的语言。
        """

    static func userPrompt(transcript: String) -> String {
        """
        请为以下会议转写生成纪要：

        \(transcript)
        """
    }

    /// 长会议分段压缩（map 阶段）用的提示词：把一段转写压成纪要素材，
    /// 最终汇总（reduce 阶段）仍用主提示词（默认或用户配置）。
    static let compressionSystemPrompt = """
        你是会议记录员。把这段会议转写压缩成纪要素材，保留：关键决议、行动项
        （含负责人与时间）、重要数字与人名、讨论脉络。250 字以内，条目式，
        忠实原文，不编造转写中没有的信息。
        """

    /// 把大段转写按字符预算切块，块间不拆行（保证每块语义完整）。
    static func makeBlocks(_ text: String, maxChars: Int) -> [String] {
        var blocks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if !current.isEmpty, current.count + line.count + 1 > maxChars {
                blocks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    /// 用给定提示词对会议片段做 map-reduce 生成。只有完整、未取消且结构有效的
    /// 结果才会返回；任何失败都向上抛，调用方不得保存部分输出。
    static func generate(
        segments: [TranscriptSegment],
        prompt: String,
        baseURL: URL,
        chat: any MeetingChatStreaming = EngineClient.shared,
        onProgress: @escaping @MainActor (Stage) -> Void = { _ in }
    ) async throws -> MinutesDocument {
        try Task.checkCancellation()
        let orderedSegments = segments.sorted { $0.sequence < $1.sequence }
        let plainTranscript = orderedSegments.map(\.text).joined(separator: "\n")
        guard !plainTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GenerationError.emptyTranscript
        }
        let transcript = orderedSegments
            .map { "[\(Formatters.stamp($0.start))] \($0.text)" }
            .joined(separator: "\n")
        let blocks = makeBlocks(transcript, maxChars: 12_000)
        guard !blocks.isEmpty else { throw GenerationError.emptyTranscript }

        func collect(_ messages: [EngineClient.ChatMessage]) async throws -> String {
            try Task.checkCancellation()
            var output = ""
            for try await token in await chat.streamChat(
                messages: messages, baseURL: baseURL, temperature: 0.3
            ) {
                try Task.checkCancellation()
                output += token
            }
            try Task.checkCancellation()
            return output
        }

        let finalText: String
        if blocks.count == 1 {
            await onProgress(.generating)
            finalText = try await collect([
                EngineClient.ChatMessage(role: "system", content: prompt),
                EngineClient.ChatMessage(role: "user", content: userPrompt(transcript: blocks[0])),
            ])
        } else {
            var drafts: [String] = []
            for (index, block) in blocks.enumerated() {
                try Task.checkCancellation()
                await onProgress(.mapping(index: index + 1, total: blocks.count))
                let draft = try await collect([
                    EngineClient.ChatMessage(role: "system", content: compressionSystemPrompt),
                    EngineClient.ChatMessage(role: "user", content: "会议转写第 \(index + 1) 段（共 \(blocks.count) 段）：\n\n\(block)"),
                ])
                drafts.append("第 \(index + 1) 段：\n\(draft)")
            }
            try Task.checkCancellation()
            await onProgress(.reducing)
            finalText = try await collect([
                EngineClient.ChatMessage(role: "system", content: prompt),
                EngineClient.ChatMessage(role: "user", content: userPrompt(transcript: drafts.joined(separator: "\n\n"))),
            ])
        }
        try Task.checkCancellation()
        let document = try parseAndValidate(finalText)
        try Task.checkCancellation()
        return document
    }

    /// 纯结构化解析；生成工作流会在返回前另外验证完整性。
    static func parse(_ text: String) -> MinutesDocument {
        var doc = MinutesDocument()
        doc.summary = section(in: text, header: "摘要")
        doc.decisions = bulletItems(in: text, header: "决议")
        doc.actionItems = bulletItems(in: text, header: "行动项")
        doc.keywords = section(in: text, header: "关键词")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return doc
    }

    // MARK: - 私有解析工具

    private static func parseAndValidate(_ text: String) throws -> MinutesDocument {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GenerationError.invalidDocument("内容为空")
        }
        for header in ["摘要", "决议", "行动项", "关键词"] {
            guard text.range(of: "## \(header)") != nil else {
                throw GenerationError.invalidDocument("缺少「\(header)」小节")
            }
        }
        let document = parse(text)
        guard !document.summary.isEmpty else {
            throw GenerationError.invalidDocument("摘要为空")
        }
        return document
    }

    private static func section(in text: String, header: String) -> String {
        guard let range = text.range(of: "## \(header)") else { return "" }
        let after = text[range.upperBound...]
        // 截到下一个小节或文末。
        if let next = after.range(of: "\n## ") {
            return after[..<next.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(after).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bulletItems(in text: String, header: String) -> [String] {
        let body = section(in: text, header: header)
        return body
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("-") || trimmed.hasPrefix("•") else { return nil }
                return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }
}
