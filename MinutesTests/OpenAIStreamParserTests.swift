import XCTest
@testable import Minutes

final class OpenAIStreamParserTests: XCTestCase {
    func testChineseAcrossEveryByteAndMultipleEvents() throws {
        let input = "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" +
            "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n" +
            "data: {\"choices\":[{\"delta\":{\"content\":\"，世界\"}}]}\n\n" +
            "data: [DONE]\n\n"
        var parser = OpenAIStreamParser()
        var events: [OpenAIStreamParser.Event] = []
        for byte in Data(input.utf8) {
            events.append(contentsOf: try parser.feed(byte))
        }
        try parser.finish()
        XCTAssertEqual(events, [.content("你好"), .content("，世界"), .done])
    }

    func testCRLFCommentsAndMultilineData() throws {
        let input = ": keep-alive\r\n\r\n" +
            "data: {\"choices\":[\r\n" +
            "data: {\"delta\":{\"content\":\"A\"}}]}\r\n\r\n" +
            "data: {\"choices\":[]}\r\n\r\n" +
            "data: [DONE]\r\n\r\n"
        var parser = OpenAIStreamParser()
        XCTAssertEqual(try parser.feed(Data(input.utf8)), [.content("A"), .done])
    }

    func testMissingDoneFailsInsteadOfSavingPartialMinutes() {
        var parser = OpenAIStreamParser()
        XCTAssertNoThrow(try parser.feed(Data("data: {\"choices\":[{\"delta\":{\"content\":\"半篇\"}}]}\n\n".utf8)))
        XCTAssertThrowsError(try parser.finish())
    }

    func testLengthFinishReasonFails() {
        var parser = OpenAIStreamParser()
        let input = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n"
        XCTAssertThrowsError(try parser.feed(Data(input.utf8)))
    }

    func testServerErrorIsPropagated() {
        var parser = OpenAIStreamParser()
        let input = "data: {\"error\":{\"message\":\"model unavailable\"}}\n\n"
        XCTAssertThrowsError(try parser.feed(Data(input.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("model unavailable"))
        }
    }

    func testMalformedJSONIsNotSilentlyIgnored() {
        var parser = OpenAIStreamParser()
        XCTAssertThrowsError(try parser.feed(Data("data: {not-json}\n\n".utf8)))
    }
}
