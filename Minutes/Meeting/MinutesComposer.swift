import Foundation

/// 纪要的提示词构造与结构化解析。纯函数集合，无副作用，可单测。
enum MinutesComposer {
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
    /// map-reduce 生成与「重新生成」共用。
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

    /// 用给定提示词对完整转写做 map-reduce 生成（会议中生成与会后
    /// 「重新生成」共用）。onProgress 回报阶段信息，便于界面展示进度。
    static func generate(
        transcript: String,
        prompt: String,
        baseURL: URL,
        onProgress: @escaping @MainActor (String) -> Void
    ) async -> MinutesDocument? {
        let blocks = makeBlocks(transcript, maxChars: 12_000)
        guard !blocks.isEmpty else { return nil }
        let client = EngineClient.shared

        func collect(_ messages: [EngineClient.ChatMessage]) async throws -> String {
            var output = ""
            for try await token in await client.streamChat(messages: messages, baseURL: baseURL) {
                output += token
            }
            return output
        }

        do {
            let finalText: String
            if blocks.count == 1 {
                await onProgress("正在生成纪要…")
                finalText = try await collect([
                    EngineClient.ChatMessage(role: "system", content: prompt),
                    EngineClient.ChatMessage(role: "user", content: userPrompt(transcript: blocks[0])),
                ])
            } else {
                var drafts: [String] = []
                for (index, block) in blocks.enumerated() {
                    await onProgress("正在整理第 \(index + 1)/\(blocks.count) 段…")
                    let draft = try await collect([
                        EngineClient.ChatMessage(role: "system", content: compressionSystemPrompt),
                        EngineClient.ChatMessage(role: "user", content: "会议转写第 \(index + 1) 段（共 \(blocks.count) 段）：\n\n\(block)"),
                    ])
                    drafts.append("第 \(index + 1) 段：\n\(draft)")
                }
                await onProgress("正在汇总纪要…")
                finalText = try await collect([
                    EngineClient.ChatMessage(role: "system", content: prompt),
                    EngineClient.ChatMessage(role: "user", content: userPrompt(transcript: drafts.joined(separator: "\n\n"))),
                ])
            }
            return parse(finalText)
        } catch {
            await onProgress("生成失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 从流式文本中尽力解析结构化字段；解析失败时保留原文。
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
