import XCTest
@testable import Minutes

final class EngineClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.setHandler(nil)
        super.tearDown()
    }

    func testASRUploadsWAVAndParsesText() async throws {
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
            let body = Self.requestBody(request)
            XCTAssertTrue(body.contains(Data("Content-Type: audio/wav".utf8)))
            XCTAssertTrue(body.contains(Data("RIFF".utf8)))
            return Self.response(request: request, status: 200, json: ["text": "你好", "language": "zh"])
        }
        let client = EngineClient(session: Self.session())
        let result = try await client.transcribe(
            [Float](repeating: 0.1, count: 16_000),
            baseURL: URL(string: "http://127.0.0.1:8797")!
        )
        XCTAssertEqual(result.text, "你好")
        XCTAssertEqual(result.language, "zh")
        XCTAssertEqual(result.duration, 1)
    }

    func testOpenAIStreamCollectsContent() async throws {
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"## 摘要\\n\"}}]}\n\n" +
            "data: {\"choices\":[{\"delta\":{\"content\":\"完成\"}}]}\n\n" +
            "data: [DONE]\n\n"
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            let body = try? JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "minutes-llm")
            XCTAssertEqual(body?["stream"] as? Bool, true)
            return Self.response(request: request, status: 200, body: Data(sse.utf8))
        }
        let client = EngineClient(session: Self.session())
        var output = ""
        for try await chunk in await client.streamChat(
            messages: [.init(role: "user", content: "测试")],
            baseURL: URL(string: "http://127.0.0.1:8788")!
        ) {
            output += chunk
        }
        XCTAssertEqual(output, "## 摘要\n完成")
    }

    func testCancellationAfterPartialContentThrows() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedStreamURLProtocolStub.self]
        let client = EngineClient(session: URLSession(configuration: configuration))
        let firstChunk = FirstChunkFlag()
        let consumption = Task<String, Error> {
            var output = ""
            for try await chunk in await client.streamChat(
                messages: [.init(role: "user", content: "测试")],
                baseURL: URL(string: "http://127.0.0.1:8788")!
            ) {
                output += chunk
                await firstChunk.mark()
            }
            return output
        }
        for _ in 0..<1_000 {
            if await firstChunk.value { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let receivedFirstChunk = await firstChunk.value
        XCTAssertTrue(receivedFirstChunk)

        consumption.cancel()
        do {
            let output = try await consumption.value
            XCTFail("取消不应正常返回部分内容：\(output)")
        } catch is CancellationError {
            // 预期取消错误。
        } catch {
            XCTFail("取消错误被替换：\(error)")
        }
    }

    func testHTTPErrorMessageIsPropagated() async {
        URLProtocolStub.setHandler { request in
            Self.response(request: request, status: 500, json: ["error": ["message": "native failure"]])
        }
        let client = EngineClient(session: Self.session())
        do {
            _ = try await client.transcribe([Float](repeating: 0, count: 16_000), baseURL: URL(string: "http://127.0.0.1")!)
            XCTFail("HTTP 500 不应成功")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("native failure"))
        }
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func response(request: URLRequest, status: Int, json: [String: Any]) -> (HTTPURLResponse, Data) {
        response(request: request, status: status, body: try! JSONSerialization.data(withJSONObject: json))
    }

    private static func response(request: URLRequest, status: Int, body: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
    }
}

private actor FirstChunkFlag {
    private(set) var value = false
    func mark() { value = true }
}

private final class SuspendedStreamURLProtocolStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"半篇\"}}]}\n\n"
        client?.urlProtocol(self, didLoad: Data(chunk.utf8))
        // 故意不结束响应，让测试能在部分内容后取消。
    }

    override func stopLoading() {}
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
