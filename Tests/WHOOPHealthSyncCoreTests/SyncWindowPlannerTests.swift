import XCTest
@testable import WHOOPHealthSyncCore

final class SyncWindowPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testRecentHeartRateIsRevisitedAfterTheCheckpointAdvances() {
        let plan = SyncWindowPlanner.makePlan(now: now, checkpoints: checkpoints(secondsAgo: 60))
        XCTAssertEqual(plan.heartRateWindow, TimeRange(start: now.addingTimeInterval(-86_400), end: now))
        XCTAssertFalse(plan.isFirstHeartRateSync)
    }

    func testOlderUnfinishedProgressIsNotTruncatedToTheRevisionWindow() {
        let plan = SyncWindowPlanner.makePlan(now: now, checkpoints: checkpoints(secondsAgo: 3 * 86_400))
        XCTAssertEqual(plan.heartRateWindow.start, now.addingTimeInterval(-3 * 86_400 - 60))
    }

    func testFirstSyncRetainsItsOwnLookbackRegardlessOfRevisionWindow() {
        let plan = SyncWindowPlanner.makePlan(now: now,
            checkpoints: SyncCheckpointState(lastHeartRateEnd: nil, lastSleepQueryEnd: nil),
            firstSyncLookbackDays: 2, heartRateRevisionLookbackDays: 5)
        XCTAssertEqual(plan.heartRateWindow.start, now.addingTimeInterval(-2 * 86_400))
        XCTAssertTrue(plan.isFirstHeartRateSync)
    }

    func testRevisionLookbackIsConfigurableAndDoesNotChangeSleepPlanning() {
        let plan = SyncWindowPlanner.makePlan(now: now, checkpoints: checkpoints(secondsAgo: 60),
            heartRateRevisionLookbackDays: 2)
        XCTAssertEqual(plan.heartRateWindow.start, now.addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(plan.sleepDiscoveryWindow.start, now.addingTimeInterval(-60))
        XCTAssertEqual(plan.sleepRevisionLookbackWindow.start, now.addingTimeInterval(-7 * 86_400))
    }

    func testZeroAndNegativeRevisionWindowsPreserveTheResolutionOverlap() {
        for days in [0, -1] {
            let plan = SyncWindowPlanner.makePlan(now: now, checkpoints: checkpoints(secondsAgo: 60),
                heartRateRevisionLookbackDays: days)
            XCTAssertEqual(plan.heartRateWindow.start, now.addingTimeInterval(-120))
        }
    }

    private func checkpoints(secondsAgo: TimeInterval) -> SyncCheckpointState {
        let end = now.addingTimeInterval(-secondsAgo)
        return SyncCheckpointState(lastHeartRateEnd: end, lastSleepQueryEnd: end, lastHeartRateResolution: 60)
    }
}
