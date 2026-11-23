import XCTest
@testable import Minutes

@MainActor
final class MinutesComposerTests: XCTestCase {
    func testEmptySegmentsThrowWithoutCallingChat() async throws {
        let chat = ComposerChatStub()
        var stages: [MinutesComposer.Stage] = []

        do {
            _ = try await MinutesComposer.generate(
                segments: [], prompt: "提示词", baseURL: Self.baseURL, chat: chat,
                onProgress: { stages.append($0) }
            )
            XCTFail("空转写不应生成纪要")
        } catch MinutesComposer.GenerationError.emptyTranscript {
            // 预期错误。
        } catch {
            XCTFail("错误类型不符：\(error)")
        }

        XCTAssertEqual(chat.requestCount(), 0)
        XCTAssertTrue(stages.isEmpty)
    }

    func testWhitespaceOnlyTranscriptThrowsWithoutCallingChat() async throws {
        let chat = ComposerChatStub()
        let segment = TranscriptSegment(start: 0, end: 1, text: " \n ", language: nil, sequence: 0)

        do {
            _ = try await MinutesComposer.generate(
                segments: [segment], prompt: "提示词", baseURL: Self.baseURL, chat: chat
            )
            XCTFail("纯空白转写不应生成纪要")
        } catch MinutesComposer.GenerationError.emptyTranscript {
            // 预期错误。
        } catch {
            XCTFail("错误类型不符：\(error)")
        }

        XCTAssertEqual(chat.requestCount(), 0)
    }

    func testCanonicalTranscriptSortsSegmentsAndAddsTimestamps() async throws {
        let chat = ComposerChatStub()
        let later = TranscriptSegment(start: 62, end: 65, text: "后续", language: nil, sequence: 1)
        let earlier = TranscriptSegment(start: 0, end: 3, text: "开始", language: nil, sequence: 0)

        _ = try await MinutesComposer.generate(
            segments: [later, earlier], prompt: "自定义提示", baseURL: Self.baseURL, chat: chat
        )

        let messages = chat.messages(at: 0)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertEqual(messages[0].content, "自定义提示")
        XCTAssertTrue(messages[1].content.contains("[00:00] 开始\n[01:02] 后续"))
    }

    func testSingleBlockEmitsStageAndParsesStructuredDocument() async throws {
        let output = """
            ## 摘要
            完整摘要

            ## 决议
            - 决议一

            ## 行动项
            - 行动一

            ## 关键词
            甲, 乙
            """
        let chat = ComposerChatStub(responses: [.output(output)])
        var stages: [MinutesComposer.Stage] = []

        let document = try await MinutesComposer.generate(
            segments: [Self.segment(text: "内容")], prompt: "提示词", baseURL: Self.baseURL,
            chat: chat, onProgress: { stages.append($0) }
        )

        XCTAssertEqual(stages, [.generating])
        XCTAssertEqual(document.summary, "完整摘要")
        XCTAssertEqual(document.decisions, ["决议一"])
        XCTAssertEqual(document.actionItems, ["行动一"])
        XCTAssertEqual(document.keywords, ["甲", "乙"])
    }

    func testLongMeetingUsesMapReduceAndReportsEveryStage() async throws {
        let chat = ComposerChatStub(responses: [
            .output("第一段素材"),
            .output("第二段素材"),
            .output(Self.validDocument),
        ])
        let segments = [
            Self.segment(text: String(repeating: "甲", count: 7_000), start: 0, sequence: 0),
            Self.segment(text: String(repeating: "乙", count: 7_000), start: 8, sequence: 1),
        ]
        var stages: [MinutesComposer.Stage] = []

        let document = try await MinutesComposer.generate(
            segments: segments, prompt: "自定义汇总提示", baseURL: Self.baseURL,
            chat: chat, onProgress: { stages.append($0) }
        )

        XCTAssertEqual(chat.requestCount(), 3)
        XCTAssertEqual(stages, [
            .mapping(index: 1, total: 2),
            .mapping(index: 2, total: 2),
            .reducing,
        ])
        XCTAssertEqual(chat.messages(at: 0)[0].content, MinutesComposer.compressionSystemPrompt)
        XCTAssertEqual(chat.messages(at: 1)[0].content, MinutesComposer.compressionSystemPrompt)
        XCTAssertEqual(chat.messages(at: 2)[0].content, "自定义汇总提示")
        XCTAssertTrue(chat.messages(at: 2)[1].content.contains("第 1 段：\n第一段素材"))
        XCTAssertTrue(chat.messages(at: 2)[1].content.contains("第 2 段：\n第二段素材"))
        XCTAssertEqual(document.summary, "测试摘要")
    }

    func testEmptyOutputMissingSectionAndEmptySummaryAreRejected() async throws {
        let responses: [ComposerChatStub.Response] = [
            .output(""),
            .output("## 摘要\n有摘要\n\n## 决议\n\n## 行动项\n"),
            .output("## 摘要\n\n## 决议\n\n## 行动项\n\n## 关键词\n"),
        ]

        for response in responses {
            let chat = ComposerChatStub(responses: [response])
            do {
                _ = try await MinutesComposer.generate(
                    segments: [Self.segment(text: "内容")], prompt: "提示词",
                    baseURL: Self.baseURL, chat: chat
                )
                XCTFail("无效文档不应返回成功结果")
            } catch let error as MinutesComposer.GenerationError {
                guard case .invalidDocument = error else {
                    XCTFail("错误类型不符：\(error)")
                    continue
                }
            } catch {
                XCTFail("错误类型不符：\(error)")
            }
        }
    }

    func testStreamFailurePropagatesWithoutReturningDocument() async throws {
        let chat = ComposerChatStub(responses: [.failure])

        do {
            _ = try await MinutesComposer.generate(
                segments: [Self.segment(text: "内容")], prompt: "提示词",
                baseURL: Self.baseURL, chat: chat
            )
            XCTFail("流失败不应返回纪要")
        } catch ComposerStubError.failed {
            // 预期原样上传错误。
        } catch {
            XCTFail("错误被替换或吞掉：\(error)")
        }
    }

    func testCancellationAfterPartialOutputThrowsInsteadOfReturningDocument() async throws {
        let chat = ComposerChatStub(responses: [.suspended("## 摘要\n部分摘要")])
        let generation = Task<MinutesDocument, Error> {
            try await MinutesComposer.generate(
                segments: [Self.segment(text: "内容")], prompt: "提示词",
                baseURL: Self.baseURL, chat: chat
            )
        }
        await waitUntil { chat.hasYieldedSuspendedOutput }

        generation.cancel()
        do {
            _ = try await generation.value
            XCTFail("取消后的部分输出不应返回纪要")
        } catch is CancellationError {
            // 预期取消。
        } catch {
            XCTFail("取消错误被替换：\(error)")
        }
    }

    private static let baseURL = URL(string: "http://127.0.0.1:8788")!
    private static let validDocument = """
        ## 摘要
        测试摘要

        ## 决议

        ## 行动项

        ## 关键词
        测试
        """

    private static func segment(
        text: String, start: TimeInterval = 0, sequence: Int = 0
    ) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 1, text: text, language: nil, sequence: sequence)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("等待条件超时")
    }
}

private final class ComposerChatStub: MeetingChatStreaming, @unchecked Sendable {
    enum Response: Sendable {
        case output(String)
        case failure
        case suspended(String)
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var requests: [[EngineClient.ChatMessage]] = []
    private var yieldedSuspendedOutput = false

    var hasYieldedSuspendedOutput: Bool {
        lock.withLock { yieldedSuspendedOutput }
    }

    private static let defaultOutput = """
        ## 摘要
        测试摘要

        ## 决议

        ## 行动项

        ## 关键词
        测试
        """

    init(responses: [Response] = []) {
        self.responses = responses
    }

    func streamChat(
        messages: [EngineClient.ChatMessage], baseURL: URL, temperature: Double
    ) async -> EngineClient.ChatStream {
        let response = lock.withLock { () -> Response in
            requests.append(messages)
            if responses.isEmpty { return .output(Self.defaultOutput) }
            return responses.removeFirst()
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            switch response {
            case .output(let output):
                continuation.yield(output)
                continuation.finish()
            case .failure:
                continuation.finish(throwing: ComposerStubError.failed)
            case .suspended(let output):
                lock.withLock { yieldedSuspendedOutput = true }
                continuation.yield(output)
            }
        }
        return EngineClient.ChatStream(stream)
    }

    func requestCount() -> Int {
        lock.withLock { requests.count }
    }

    func messages(at index: Int) -> [EngineClient.ChatMessage] {
        lock.withLock { requests[index] }
    }
}

private enum ComposerStubError: Error {
    case failed
}
