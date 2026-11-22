import Foundation
import Testing
@testable import ClientCore

/// Pins the compact stamps and status words the card list renders, so the
/// 16/15 pt card layout cannot silently change the values' meaning.
@Suite @MainActor struct DeviceSessionPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func compactStampsFollowTheOfficialBuckets() {
        #expect(DeviceSessionTime.compact(now.addingTimeInterval(-30), now: now) == "刚刚")
        #expect(DeviceSessionTime.compact(now.addingTimeInterval(-60), now: now) == "1分钟")
        #expect(DeviceSessionTime.compact(now.addingTimeInterval(-59 * 60), now: now) == "59分钟")
        #expect(DeviceSessionTime.compact(now.addingTimeInterval(-3_599), now: now) == "59分钟")
        #expect(DeviceSessionTime.compact(now.addingTimeInterval(-3_600), now: now) == "1小时")
        #expect(DeviceSessionTime.compact(now.addingTimeInterval(-86_399), now: now) == "23小时")
        #expect(DeviceSessionTime.compact(now.addingTimeInterval(-2 * 86_400), now: now) == "2天")
        #expect(DeviceSessionTime.compact(nil, now: now) == nil)
    }

    @Test func futureDatesReadAsJustNow() {
        #expect(DeviceSessionTime.compact(now.addingTimeInterval(120), now: now) == "刚刚")
    }

    @Test func connectionWordsFollowTheServerPresence() {
        #expect(DeviceSessionConnection.text(.online) == "已连接")
        #expect(DeviceSessionConnection.text(.offline) == "离线")
        #expect(DeviceSessionConnection.text(.unknown) == "未知")
        #expect(DeviceSessionConnection.isConnected(.online))
        #expect(!DeviceSessionConnection.isConnected(.offline))
    }

    @Test func liveRingBelongsToActiveStatesOnly() {
        for status in [V2RuntimeStatus.running, .waiting, .waitingApproval, .pending, .stopping, .blocked] {
            #expect(DeviceSessionActivity.isRunning(status))
        }
        for status in [V2RuntimeStatus.idle, .error, .disconnected, .unknown] {
            #expect(!DeviceSessionActivity.isRunning(status))
        }
        #expect(DeviceSessionActivity.isAlert(.waitingApproval))
        #expect(DeviceSessionActivity.isAlert(.blocked))
        #expect(DeviceSessionActivity.isAlert(.error))
        #expect(!DeviceSessionActivity.isAlert(.running))
    }
}
