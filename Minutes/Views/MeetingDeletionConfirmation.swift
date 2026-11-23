import Foundation

/// 历史会议删除的两段式确认状态。时间由调用方注入，界面使用单调时钟，测试可精确覆盖边界。
struct MeetingDeletionConfirmation {
    enum ArmResult: Equatable {
        case armed
        case rejectedBatch
    }

    static let minimumConfirmationInterval: TimeInterval = 0.3
    static let confirmationWindow: TimeInterval = 5

    private(set) var pendingMeetingID: UUID?
    private(set) var armedAt: TimeInterval?

    /// 只接受单个目标。重复触发同一目标不会延长确认窗口；切换目标会重新计时。
    @discardableResult
    mutating func arm(targets: [UUID], at now: TimeInterval) -> ArmResult {
        guard targets.count == 1, let target = targets.first else {
            cancel()
            return .rejectedBatch
        }
        if pendingMeetingID == target { return .armed }
        pendingMeetingID = target
        armedAt = now
        return .armed
    }

    /// 返回 true 才允许调用 Store；防双击期内保留状态，超时则安全复位。
    mutating func confirm(meetingID: UUID, at now: TimeInterval) -> Bool {
        guard pendingMeetingID == meetingID, let armedAt else { return false }
        let elapsed = now - armedAt
        // 例如 100.3 - 100 会略小于字面量 0.3，不能让浮点表示误差拒绝边界确认。
        let delaySatisfied = elapsed >= Self.minimumConfirmationInterval
            || abs(elapsed - Self.minimumConfirmationInterval) < 0.000_000_001
        guard delaySatisfied else { return false }
        guard elapsed < Self.confirmationWindow else {
            cancel()
            return false
        }
        cancel()
        return true
    }

    mutating func cancelIfExpired(at now: TimeInterval) {
        guard let armedAt, now - armedAt >= Self.confirmationWindow else { return }
        cancel()
    }

    mutating func cancel() {
        pendingMeetingID = nil
        armedAt = nil
    }
}
