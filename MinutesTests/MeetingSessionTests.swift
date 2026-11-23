import XCTest
@testable import Minutes

@MainActor
final class MeetingSessionTests: XCTestCase {
    func testResumeKeepsCreatedAtAndRecordingTimelineAcrossPauses() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let session = MeetingSession(
            store: makeStore(),
            capture: capture,
            transcriber: TranscriberStub(),
            readiness: { _ in true },
            now: { clock.now }
        )

        session.start()
        await waitUntil { capture.isRunning }
        let createdAt = session.meeting.createdAt

        clock.advance(by: 5)
        await session.pause()
        XCTAssertEqual(session.meeting.createdAt, createdAt)
        XCTAssertEqual(session.meeting.duration, 5, accuracy: 0.001)

        clock.advance(by: 60)
        await session.resume()
        await waitUntil { capture.isRunning }
        XCTAssertEqual(session.meeting.createdAt, createdAt)
        XCTAssertEqual(session.elapsed, 5, accuracy: 0.001)

        clock.advance(by: 3)
        await session.pause()
        XCTAssertEqual(session.meeting.createdAt, createdAt)
        XCTAssertEqual(session.meeting.duration, 8, accuracy: 0.001)
    }

    func testRecognitionClosesOnlyItsSnapshotAndPreservesLaterAudio() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let session = MeetingSession(
            store: makeStore(), capture: capture, transcriber: transcriber,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }

        let chunk = Array(repeating: Float(0.1), count: 24_000) // 1.5 秒
        for index in 0..<4 {
            capture.yield(samples: chunk)
            await waitUntil { await transcriber.requestCount() == index + 1 }
            if index < 3 {
                await transcriber.resolveRequest(at: index, text: "仍在说")
                await waitUntil { session.interimText == "仍在说" }
            }
        }

        capture.yield(samples: Array(repeating: Float(0.1), count: 16_000)) // 快照外 1 秒
        await transcriber.resolveRequest(at: 3, text: "第一段。")
        await waitUntil { session.meeting.segments.count == 1 }

        XCTAssertEqual(session.meeting.segments[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(session.meeting.segments[0].end, 6, accuracy: 0.001)

        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000)) // 下一段达到 1.5 秒
        await waitUntil { await transcriber.requestCount() == 5 }
        let retainedSamples = await transcriber.sampleCount(at: 4)
        XCTAssertEqual(retainedSamples, 24_000)

        await transcriber.resolveRequest(at: 4, text: "后续")
        await waitUntil { session.interimText == "后续" }
        await session.pause()
    }

    func testFinishWaitsForFinalTranscriptionBeforeSaving() async throws {
        let store = makeStore()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let chat = ChatStub()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: chat,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }

        let finishing = Task { await session.finish() }
        await waitUntil { await transcriber.requestCount() == 1 }
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertEqual(chat.requestCount(), 0)

        await transcriber.resolveRequest(at: 0, text: "最后一句。")
        await finishing.value

        XCTAssertEqual(session.phase, .completed)
        XCTAssertEqual(store.meetings.count, 1)
        let savedMeeting = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(savedMeeting.segments.map(\.text), ["最后一句。"])
        XCTAssertEqual(savedMeeting.segments[0].end, 0.5, accuracy: 0.001)
        XCTAssertEqual(chat.requestCount(), 2) // 纪要与非阻塞标题
    }

    func testFinalTranscriptionFailureIsRetryableWithoutSaving() async throws {
        let store = makeStore()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let chat = ChatStub()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: chat,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }

        let firstFinish = Task { await session.finish() }
        await waitUntil { await transcriber.requestCount() == 1 }
        await transcriber.failRequest(at: 0)
        await firstFinish.value

        XCTAssertNotEqual(session.phase, .completed)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertEqual(chat.requestCount(), 0)

        let retry = Task { await session.finish() }
        await waitUntil { await transcriber.requestCount() == 2 }
        await transcriber.resolveRequest(at: 1, text: "恢复后的最后一句。")
        await retry.value

        XCTAssertEqual(session.phase, .completed)
        let requestCount = await transcriber.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(chat.requestCount(), 2)
        let savedMeeting = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(savedMeeting.segments.map(\.text), ["恢复后的最后一句。"])
    }

    func testSaveFailureKeepsMeetingUnsavedAndRetryDoesNotRecompute() async throws {
        let (store, directory) = makeFailingStore()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let chat = ChatStub()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: chat,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }

        let firstFinish = Task { await session.finish() }
        await waitUntil { await transcriber.requestCount() == 1 }
        await transcriber.resolveRequest(at: 0, text: "需要可靠保存。")
        await firstFinish.value

        XCTAssertNotEqual(session.phase, .completed)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertNotNil(session.meeting.minutes)
        XCTAssertTrue(store.meetings.isEmpty)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await session.finish()

        XCTAssertEqual(session.phase, .completed)
        let requestCount = await transcriber.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(chat.requestCount(), 2)
        let savedMeeting = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(savedMeeting.transcriptText, "需要可靠保存。")
    }

    func testConcurrentFinishCallsShareTheSameTransaction() async throws {
        let store = makeStore()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let chat = ChatStub()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: chat,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }

        let firstFinish = Task { await session.finish() }
        await waitUntil { await transcriber.requestCount() == 1 }
        let secondReturned = CompletionFlag()
        let secondFinish = Task {
            await session.finish()
            await secondReturned.mark()
        }
        for _ in 0..<10 { await Task.yield() }
        let returnedEarly = await secondReturned.value
        XCTAssertFalse(returnedEarly)

        await transcriber.resolveRequest(at: 0, text: "只生成一次。")
        await firstFinish.value
        await secondFinish.value

        let requestCount = await transcriber.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(chat.requestCount(), 2)
        XCTAssertEqual(store.meetings.count, 1)
        XCTAssertEqual(session.phase, .completed)
    }

    func testEmptyMeetingDoesNotGenerateSaveOrComplete() async throws {
        let store = makeStore()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let chat = ChatStub()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: chat,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }

        await session.finish()

        XCTAssertNotEqual(session.phase, .completed)
        XCTAssertEqual(session.errorMessage, "没有可生成纪要的内容，请继续录制或放弃会议。")
        XCTAssertEqual(chat.requestCount(), 0)
        XCTAssertTrue(store.meetings.isEmpty)

        await session.resume()
        await waitUntil { capture.isRunning }
        XCTAssertEqual(session.phase, .live)
        await session.pause()
    }

    func testDiscardStopsCaptureAndIgnoresLateRecognition() async throws {
        let store = makeStore()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let chat = ChatStub()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: chat,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 24_000), rms: 0.5)
        await waitUntil { await transcriber.requestCount() == 1 }

        await session.discard()

        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(capture.isRunning)
        XCTAssertTrue(store.meetings.isEmpty)

        await transcriber.resolveRequest(at: 0, text: "迟到的识别")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(session.meeting.segments.isEmpty)
        XCTAssertEqual(chat.requestCount(), 0)
    }

    func testPauseDrainsRecognitionAndResumePreservesBufferedAudio() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let session = MeetingSession(
            store: makeStore(), capture: capture, transcriber: transcriber,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 24_000), rms: 0.5)
        await waitUntil { await transcriber.requestCount() == 1 }

        let pauseReturned = CompletionFlag()
        let pausing = Task {
            await session.pause()
            await pauseReturned.mark()
        }
        for _ in 0..<10 { await Task.yield() }
        let returnedEarly = await pauseReturned.value
        XCTAssertFalse(returnedEarly)

        await transcriber.resolveRequest(at: 0, text: "暂停前保留")
        await pausing.value
        XCTAssertEqual(session.phase, .paused)
        XCTAssertEqual(session.interimText, "暂停前保留")
        XCTAssertTrue(session.meeting.segments.isEmpty)

        await session.resume()
        await waitUntil { capture.isRunning }
        var requestCount = await transcriber.requestCount()
        XCTAssertEqual(requestCount, 1)

        capture.yield(samples: Array(repeating: Float(0.1), count: 24_000))
        await waitUntil { await transcriber.requestCount() == 2 }
        let resumedSamples = await transcriber.sampleCount(at: 1)
        XCTAssertEqual(resumedSamples, 48_000)

        await transcriber.resolveRequest(at: 1, text: "继续后的快照")
        await session.pause()
        requestCount = await transcriber.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testPauseRecognitionFailureRetriesBeforeResume() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let session = MeetingSession(
            store: makeStore(), capture: capture, transcriber: transcriber,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 24_000), rms: 0.5)
        await waitUntil { await transcriber.requestCount() == 1 }

        let pausing = Task { await session.pause() }
        await transcriber.failRequest(at: 0)
        await pausing.value

        XCTAssertEqual(session.phase, .paused)
        XCTAssertNotNil(session.errorMessage)

        let resuming = Task { await session.resume() }
        await waitUntil { await transcriber.requestCount() == 2 }
        XCTAssertFalse(capture.isRunning)
        let retrySamples = await transcriber.sampleCount(at: 1)
        XCTAssertEqual(retrySamples, 24_000)

        await transcriber.resolveRequest(at: 1, text: "恢复识别")
        await resuming.value
        XCTAssertEqual(session.phase, .live)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(session.interimText, "恢复识别")
        XCTAssertTrue(capture.isRunning)

        await session.pause()
    }

    func testLateRecognitionResultsCannotOverwriteNewerState() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let session = MeetingSession(
            store: makeStore(), capture: capture, transcriber: transcriber,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        let chunk = Array(repeating: Float(0.1), count: 24_000)

        capture.yield(samples: chunk)
        await waitUntil { await transcriber.requestCount() == 1 }
        capture.yield(samples: chunk)
        await waitUntil { await transcriber.requestCount() == 2 }
        await transcriber.resolveRequest(at: 1, text: "新 interim")
        await waitUntil { session.interimText == "新 interim" }
        await transcriber.resolveRequest(at: 0, text: "旧 interim")
        await waitUntil { await transcriber.requestCount() == 2 }
        XCTAssertEqual(session.interimText, "新 interim")

        capture.yield(samples: chunk)
        await waitUntil { await transcriber.requestCount() == 3 }
        capture.yield(samples: chunk)
        await waitUntil { await transcriber.requestCount() == 4 }
        await transcriber.resolveRequest(at: 3, text: "有效新段。")
        await waitUntil { session.meeting.segments.count == 1 }
        await transcriber.resolveRequest(at: 2, text: "过期旧段。")
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(session.meeting.segments.map(\.text), ["有效新段。"])
        XCTAssertEqual(session.meeting.segments[0].end, 6, accuracy: 0.001)
        await session.pause()
    }

    func testMinutesFailureRetriesWithoutRepeatingFinalTranscription() async throws {
        let store = makeStore()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let chat = ChatStub()
        chat.failNextMinutesRequest()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: chat,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }

        let firstFinish = Task { await session.finish() }
        await waitUntil { await transcriber.requestCount() == 1 }
        await transcriber.resolveRequest(at: 0, text: "已定稿内容。")
        await firstFinish.value

        XCTAssertEqual(session.phase, .failed)
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertEqual(chat.requestCount(), 1)

        await session.finish()

        XCTAssertEqual(session.phase, .completed)
        let requestCount = await transcriber.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(chat.requestCount(), 3)
        XCTAssertEqual(store.meetings.count, 1)
    }

    func testFinishCannotStartWhilePauseIsDraining() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let session = MeetingSession(
            store: makeStore(), capture: capture, transcriber: transcriber,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 24_000), rms: 0.5)
        await waitUntil { await transcriber.requestCount() == 1 }

        let pausing = Task { await session.pause() }
        let finishing = Task { await session.finish() }
        for _ in 0..<10 { await Task.yield() }
        var requestCount = await transcriber.requestCount()
        XCTAssertEqual(requestCount, 1)

        await transcriber.resolveRequest(at: 0, text: "收束中的音频")
        if requestCount == 2 {
            await transcriber.resolveRequest(at: 1, text: "不应并发的冲刷")
        }
        await pausing.value
        await finishing.value
        await session.discard()

        requestCount = await transcriber.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testDiscardDuringFinalTranscriptionDoesNotSaveOrCompose() async throws {
        let store = makeStore()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let chat = ChatStub()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: chat,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }

        let finishing = Task { await session.finish() }
        await waitUntil { await transcriber.requestCount() == 1 }
        await session.discard()
        await transcriber.resolveRequest(at: 0, text: "放弃后的迟到结果")
        await finishing.value

        XCTAssertEqual(session.phase, .idle)
        XCTAssertTrue(session.meeting.segments.isEmpty)
        XCTAssertEqual(chat.requestCount(), 0)
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testDiscardDuringResumeRetryDoesNotRestartCapture() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let session = MeetingSession(
            store: makeStore(), capture: capture, transcriber: transcriber,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 24_000), rms: 0.5)
        await waitUntil { await transcriber.requestCount() == 1 }

        let pausing = Task { await session.pause() }
        await transcriber.failRequest(at: 0)
        await pausing.value
        let resuming = Task { await session.resume() }
        await waitUntil { await transcriber.requestCount() == 2 }

        await session.discard()
        await transcriber.resolveRequest(at: 1, text: "放弃后的重试结果")
        await resuming.value

        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(capture.isRunning)
        XCTAssertTrue(session.meeting.segments.isEmpty)
    }

    func testDiscardWhileFinishWaitsForPauseDrainStaysDiscarded() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let session = MeetingSession(
            store: makeStore(), capture: capture, transcriber: transcriber,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 24_000), rms: 0.5)
        await waitUntil { await transcriber.requestCount() == 1 }

        let finishing = Task { await session.finish() }
        await waitUntil { session.phase == .paused }
        await session.discard()
        await transcriber.resolveRequest(at: 0, text: "暂停 drain 的迟到结果")
        await finishing.value

        XCTAssertEqual(session.phase, .idle)
        XCTAssertTrue(session.meeting.segments.isEmpty)
        XCTAssertFalse(capture.isRunning)
    }

    func testPauseBeforeCaptureTaskStartsDoesNotLeaveCaptureRunning() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let session = MeetingSession(
            store: makeStore(), capture: capture, transcriber: TranscriberStub(),
            readiness: { _ in true }, now: { clock.now }
        )

        session.start()
        await session.pause()

        XCTAssertEqual(session.phase, .paused)
        XCTAssertFalse(capture.isRunning)
    }

    func testDiscardBeforeCaptureTaskStartsDoesNotLeaveCaptureRunning() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let session = MeetingSession(
            store: makeStore(), capture: capture, transcriber: TranscriberStub(),
            readiness: { _ in true }, now: { clock.now }
        )

        session.start()
        await session.discard()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(capture.isRunning)
    }

    func testDiscardDuringMinutesDoesNotSavePartialResult() async throws {
        let store = makeStore()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let chat = ChatStub()
        chat.suspendNextMinutesRequest()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: chat,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }

        let finishing = Task { await session.finish() }
        await waitUntil { await transcriber.requestCount() == 1 }
        await transcriber.resolveRequest(at: 0, text: "已经定稿的内容。")
        await waitUntil { session.phase == .composing && chat.requestCount() == 1 }

        await session.discard()
        await finishing.value

        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.meeting.minutes)
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testSlowTitleFallsBackWithoutBlockingSave() async throws {
        let store = makeStore()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let chat = ChatStub()
        chat.delayNextTitle(nanoseconds: 200_000_000)
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: chat,
            readiness: { _ in true }, now: { clock.now }, titleTimeout: 0.01
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }

        let finishing = Task { await session.finish() }
        await waitUntil { await transcriber.requestCount() == 1 }
        await transcriber.resolveRequest(at: 0, text: "标题不能阻塞保存。")
        await finishing.value

        XCTAssertEqual(session.phase, .completed)
        XCTAssertNotEqual(session.meeting.title, "测试标题")
        XCTAssertTrue(session.meeting.title.hasSuffix("会议"))
        let savedMeeting = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(savedMeeting.title, session.meeting.title)
        XCTAssertEqual(savedMeeting.transcriptText, "标题不能阻塞保存。")
    }

    func testRecordingPersistsMeetingAudioToDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let session = MeetingSession(
            store: MeetingsStore(directory: directory), capture: capture,
            transcriber: TranscriberStub(), readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }

        let samples = Array(repeating: Float(0.25), count: 8_000)
        capture.yield(samples: samples, rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }
        await session.pause()

        let audioURL = directory.appendingPathComponent("\(session.meeting.id.uuidString).wav")
        XCTAssertEqual(try Data(contentsOf: audioURL), try WAVEncoder.encode(samples))
    }

    func testPauseAndResumeKeepMeetingAudioContinuous() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let session = MeetingSession(
            store: MeetingsStore(directory: directory), capture: capture,
            transcriber: TranscriberStub(), readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }

        let beforePause = Array(repeating: Float(0.25), count: 8_000)
        capture.yield(samples: beforePause, rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }
        await session.pause()

        await session.resume()
        await waitUntil { capture.isRunning }
        let afterResume = Array(repeating: Float(-0.25), count: 8_000)
        // 用不同的 rms 作消费信号：energyRing 在暂停后仍保留上一段的值。
        capture.yield(samples: afterResume, rms: 0.04)
        await waitUntil { abs((session.energyRing.last ?? 0) - 0.48) < 0.001 }
        await session.pause()

        let audioURL = directory.appendingPathComponent("\(session.meeting.id.uuidString).wav")
        XCTAssertEqual(try Data(contentsOf: audioURL), try WAVEncoder.encode(beforePause + afterResume))
    }

    func testClosingSegmentWritesDraftSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let session = MeetingSession(
            store: MeetingsStore(directory: directory), capture: capture,
            transcriber: transcriber, readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }

        let chunk = Array(repeating: Float(0.1), count: 24_000) // 1.5 秒
        for index in 0..<4 {
            capture.yield(samples: chunk)
            await waitUntil { await transcriber.requestCount() == index + 1 }
            if index < 3 {
                await transcriber.resolveRequest(at: index, text: "仍在说")
                await waitUntil { session.interimText == "仍在说" }
            }
        }
        await transcriber.resolveRequest(at: 3, text: "第一段。")
        await waitUntil { session.meeting.segments.count == 1 }

        let draft = try XCTUnwrap(MeetingDraftStore(directory: directory).load(id: session.meeting.id))
        XCTAssertEqual(draft.meeting.segments.map(\.text), ["第一段。"])
        XCTAssertEqual(draft.bufferStartSample, 96_000) // 已落定 6 秒音频
        await session.pause()
    }

    func testPeriodicDraftSnapshotWithoutClosedSegment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let session = MeetingSession(
            store: MeetingsStore(directory: directory), capture: capture,
            transcriber: TranscriberStub(), readiness: { _ in true }, now: { clock.now },
            draftInterval: 0.05
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }

        // 持续讲话无落定：兜底快照也要持久化会议与已落定位置。
        await waitUntil { MeetingDraftStore(directory: directory).load(id: session.meeting.id) != nil }
        let draft = try XCTUnwrap(MeetingDraftStore(directory: directory).load(id: session.meeting.id))
        XCTAssertEqual(draft.bufferStartSample, 0)
        XCTAssertTrue(draft.meeting.segments.isEmpty)
        await session.pause()
    }

    func testFinishDeletesDraftAndKeepsAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingsStore(directory: directory)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber, chat: ChatStub(),
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }

        let finishing = Task { await session.finish() }
        await waitUntil { await transcriber.requestCount() == 1 }
        await transcriber.resolveRequest(at: 0, text: "最后一句。")
        await finishing.value

        XCTAssertEqual(session.phase, .completed)
        XCTAssertNil(MeetingDraftStore(directory: directory).load(id: session.meeting.id))
        let audioURL = directory.appendingPathComponent("\(session.meeting.id.uuidString).wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory
            .appendingPathComponent("\(session.meeting.id.uuidString).draft").path))
    }

    func testDiscardDeletesDraftAndAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let session = MeetingSession(
            store: MeetingsStore(directory: directory), capture: capture,
            transcriber: TranscriberStub(), readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }
        await session.pause()

        let audioURL = directory.appendingPathComponent("\(session.meeting.id.uuidString).wav")
        XCTAssertNotNil(MeetingDraftStore(directory: directory).load(id: session.meeting.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        await session.discard()

        XCTAssertNil(MeetingDraftStore(directory: directory).load(id: session.meeting.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testDraftSaveFailureIsVisibleAndDoesNotBlockRecording() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let session = MeetingSession(
            store: MeetingsStore(directory: directory), capture: capture,
            transcriber: TranscriberStub(), readiness: { _ in true }, now: { clock.now },
            draftInterval: 0.05
        )
        // 故障注入：草稿路径被同名目录占据，原子写必然失败。
        let draftURL = directory.appendingPathComponent("\(session.meeting.id.uuidString).draft")
        try FileManager.default.createDirectory(at: draftURL, withIntermediateDirectories: true)

        session.start()
        await waitUntil { capture.isRunning }
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.5)
        await waitUntil { session.energyRing.last == 1 }
        await waitUntil { session.errorMessage?.contains("自动保存失败") == true }

        // 录制不被阻断：后续音频照常消费，会话仍在录制中。
        capture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.04)
        await waitUntil { abs((session.energyRing.last ?? 0) - 0.48) < 0.001 }
        XCTAssertEqual(session.phase, .live)
        await session.pause()
    }

    func testRestoredSessionResumesWithoutReTranscribingFinalizedAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingsStore(directory: directory)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let capture = ScriptedCapture()
        let transcriber = TranscriberStub()
        let session = MeetingSession(
            store: store, capture: capture, transcriber: transcriber,
            readiness: { _ in true }, now: { clock.now }
        )
        session.start()
        await waitUntil { capture.isRunning }
        let chunk = Array(repeating: Float(0.1), count: 24_000) // 1.5 秒
        for index in 0..<4 {
            capture.yield(samples: chunk)
            await waitUntil { await transcriber.requestCount() == index + 1 }
            if index < 3 {
                await transcriber.resolveRequest(at: index, text: "仍在说")
                await waitUntil { session.interimText == "仍在说" }
            }
        }
        await transcriber.resolveRequest(at: 3, text: "第一段。")
        await waitUntil { session.meeting.segments.count == 1 }
        capture.yield(samples: Array(repeating: Float(0.1), count: 16_000), rms: 0.5) // 未识别尾部 1 秒
        await waitUntil { session.energyRing.last == 1 }
        await session.pause()

        // 模拟崩溃后重启：从草稿快照与 WAV 恢复会话。
        let draft = try XCTUnwrap(MeetingDraftStore(directory: directory).load(id: session.meeting.id))
        let resumedCapture = ScriptedCapture()
        let resumedTranscriber = TranscriberStub()
        let restored = try MeetingSession(
            restoring: draft, store: store, capture: resumedCapture,
            transcriber: resumedTranscriber, chat: ChatStub(),
            readiness: { _ in true }, now: { clock.now }
        )
        XCTAssertEqual(restored.phase, .paused) // 恢复到暂停态，手动继续才开麦
        XCTAssertEqual(restored.meeting.segments.map(\.text), ["第一段。"])
        XCTAssertEqual(restored.meeting.createdAt, session.meeting.createdAt)
        XCTAssertEqual(restored.meeting.duration, session.meeting.duration)

        await restored.resume()
        await waitUntil { resumedCapture.isRunning }
        resumedCapture.yield(samples: Array(repeating: Float(0.1), count: 8_000)) // 尾部凑满 1.5 秒
        await waitUntil { await resumedTranscriber.requestCount() == 1 }
        // 只提交未识别尾部与新音频，不重复已落定的 6 秒。
        let submitted = await resumedTranscriber.sampleCount(at: 0)
        XCTAssertEqual(submitted, 24_000)
        await resumedTranscriber.resolveRequest(at: 0, text: "尾部")
        await waitUntil { restored.interimText == "尾部" }

        resumedCapture.yield(samples: Array(repeating: Float(0.1), count: 8_000), rms: 0.04)
        await waitUntil { abs((restored.energyRing.last ?? 0) - 0.48) < 0.001 }
        await restored.pause()
        // 续录追加同一 WAV：7 秒旧音频 + 1 秒新音频。
        let audioURL = directory.appendingPathComponent("\(session.meeting.id.uuidString).wav")
        XCTAssertEqual(try Data(contentsOf: audioURL).count, 44 + (112_000 + 16_000) * 2)
    }

    private func makeFailingStore() -> (MeetingsStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionTests-\(UUID().uuidString)", isDirectory: true)
        FileManager.default.createFile(atPath: directory.path, contents: Data())
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (MeetingsStore(directory: directory), directory)
    }

    private func makeStore() -> MeetingsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MeetingsStore(directory: directory)
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("等待条件超时")
    }
}

private final class TestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

private final class ScriptedCapture: MeetingAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<CapturedChunk>.Continuation?
    private var running = false

    var isRunning: Bool {
        lock.withLock { running }
    }

    func start() throws -> AsyncStream<CapturedChunk> {
        let stream = AsyncStream<CapturedChunk> { continuation in
            lock.withLock {
                self.continuation = continuation
                running = true
            }
        }
        return stream
    }

    func stop() {
        let continuation = lock.withLock { () -> AsyncStream<CapturedChunk>.Continuation? in
            running = false
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    func yield(samples: [Float], rms: Float = 0) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(CapturedChunk(samples: samples, rms: rms))
    }
}

private final class ChatStub: MeetingChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [[EngineClient.ChatMessage]] = []
    private var minutesFailuresRemaining = 0
    private var minutesSuspensionsRemaining = 0
    private var titleDelayNanoseconds: UInt64 = 0

    func streamChat(
        messages: [EngineClient.ChatMessage], baseURL: URL, temperature: Double
    ) async -> EngineClient.ChatStream {
        let isTitle = messages.first?.content.contains("概括会议主题") == true
        let shouldFail = lock.withLock { () -> Bool in
            requests.append(messages)
            guard !isTitle, minutesFailuresRemaining > 0 else { return false }
            minutesFailuresRemaining -= 1
            return true
        }
        let shouldSuspend = lock.withLock { () -> Bool in
            guard !isTitle, minutesSuspensionsRemaining > 0 else { return false }
            minutesSuspensionsRemaining -= 1
            return true
        }
        let output = isTitle ? "测试标题" : "## 摘要\n测试摘要\n\n## 决议\n\n## 行动项\n\n## 关键词"
        let titleDelay = lock.withLock { () -> UInt64 in
            guard isTitle else { return 0 }
            defer { titleDelayNanoseconds = 0 }
            return titleDelayNanoseconds
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            if isTitle, titleDelay > 0 {
                let task = Task {
                    do {
                        try await Task.sleep(nanoseconds: titleDelay)
                        continuation.yield(output)
                        continuation.finish()
                    } catch {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            } else if shouldSuspend {
                continuation.yield("## 摘要\n不应保存的部分摘要")
            } else if shouldFail {
                continuation.finish(throwing: StubError.minutesFailed)
            } else {
                continuation.yield(output)
                continuation.finish()
            }
        }
        return EngineClient.ChatStream(stream)
    }

    func failNextMinutesRequest() {
        lock.withLock { minutesFailuresRemaining += 1 }
    }

    func suspendNextMinutesRequest() {
        lock.withLock { minutesSuspensionsRemaining += 1 }
    }

    func delayNextTitle(nanoseconds: UInt64) {
        lock.withLock { titleDelayNanoseconds = nanoseconds }
    }

    func requestCount() -> Int {
        lock.withLock { requests.count }
    }
}

private actor TranscriberStub: MeetingTranscribing {
    private var requests: [[Float]] = []
    private var continuations: [Int: CheckedContinuation<EngineClient.ASRResult, Error>] = [:]

    func transcribe(_ samples: [Float], baseURL: URL) async throws -> EngineClient.ASRResult {
        let index = requests.count
        requests.append(samples)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func requestCount() -> Int { requests.count }

    func sampleCount(at index: Int) -> Int { requests[index].count }

    func resolveRequest(at index: Int, text: String) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        continuation.resume(returning: EngineClient.ASRResult(
            text: text, language: "zh", duration: Double(requests[index].count) / 16_000
        ))
    }

    func failRequest(at index: Int) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        continuation.resume(throwing: StubError.recognitionFailed)
    }
}

private actor CompletionFlag {
    private(set) var value = false
    func mark() { value = true }
}

private enum StubError: Error {
    case recognitionFailed
    case minutesFailed
}
