import XCTest
@testable import Minutes

final class MeetingDeletionConfirmationTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()

    func testFirstTriggerArmsWithoutConfirming() {
        var state = MeetingDeletionConfirmation()

        let result = state.arm(targets: [first], at: 100)

        XCTAssertEqual(result, .armed)
        XCTAssertEqual(state.pendingMeetingID, first)
        XCTAssertFalse(state.confirm(meetingID: first, at: 100))
        XCTAssertEqual(state.pendingMeetingID, first)
    }

    func testConfirmationDuringDoubleClickIntervalIsIgnored() {
        var state = MeetingDeletionConfirmation()
        state.arm(targets: [first], at: 100)

        XCTAssertFalse(state.confirm(meetingID: first, at: 100.299))
        XCTAssertEqual(state.pendingMeetingID, first)
    }

    func testConfirmationAfterDelaySucceedsAndResets() {
        var state = MeetingDeletionConfirmation()
        state.arm(targets: [first], at: 100)

        XCTAssertTrue(state.confirm(meetingID: first, at: 100.3))
        XCTAssertNil(state.pendingMeetingID)
        XCTAssertNil(state.armedAt)
        XCTAssertFalse(state.confirm(meetingID: first, at: 101))
    }

    func testConfirmationAtTimeoutIsRejectedAndResets() {
        var state = MeetingDeletionConfirmation()
        state.arm(targets: [first], at: 100)

        XCTAssertFalse(state.confirm(meetingID: first, at: 105))
        XCTAssertNil(state.pendingMeetingID)
    }

    func testTimeoutCancellationIsSafeAndDoesNotDelete() {
        var state = MeetingDeletionConfirmation()
        state.arm(targets: [first], at: 100)
        state.cancelIfExpired(at: 104.999)

        XCTAssertEqual(state.pendingMeetingID, first)

        state.cancelIfExpired(at: 105)

        XCTAssertNil(state.pendingMeetingID)
        XCTAssertFalse(state.confirm(meetingID: first, at: 105.1))
    }

    func testSwitchingTargetReplacesPreviousAndRestartsTiming() {
        var state = MeetingDeletionConfirmation()
        state.arm(targets: [first], at: 100)

        state.arm(targets: [second], at: 101)

        XCTAssertEqual(state.pendingMeetingID, second)
        XCTAssertFalse(state.confirm(meetingID: first, at: 101.3))
        XCTAssertEqual(state.pendingMeetingID, second)
        XCTAssertFalse(state.confirm(meetingID: second, at: 101.299))
        XCTAssertTrue(state.confirm(meetingID: second, at: 101.3))
    }

    func testRepeatedTriggerOfSameTargetDoesNotExtendWindow() {
        var state = MeetingDeletionConfirmation()
        state.arm(targets: [first], at: 100)

        state.arm(targets: [first], at: 104)

        XCTAssertFalse(state.confirm(meetingID: first, at: 105))
        XCTAssertNil(state.pendingMeetingID)
    }

    func testCancelClearsPendingTarget() {
        var state = MeetingDeletionConfirmation()
        state.arm(targets: [first], at: 100)

        state.cancel()

        XCTAssertNil(state.pendingMeetingID)
        XCTAssertNil(state.armedAt)
        XCTAssertFalse(state.confirm(meetingID: first, at: 101))
    }

    func testBatchRequestIsRejectedWithoutSelectingTarget() {
        var state = MeetingDeletionConfirmation()

        XCTAssertEqual(state.arm(targets: [first, second], at: 100), .rejectedBatch)
        XCTAssertNil(state.pendingMeetingID)
        XCTAssertEqual(state.arm(targets: [], at: 100), .rejectedBatch)
        XCTAssertNil(state.pendingMeetingID)
    }

    func testBatchRejectionAlsoCancelsPreviouslyArmedTarget() {
        var state = MeetingDeletionConfirmation()
        state.arm(targets: [first], at: 100)

        XCTAssertEqual(state.arm(targets: [first, second], at: 101), .rejectedBatch)

        XCTAssertNil(state.pendingMeetingID)
        XCTAssertFalse(state.confirm(meetingID: first, at: 102))
    }
}
