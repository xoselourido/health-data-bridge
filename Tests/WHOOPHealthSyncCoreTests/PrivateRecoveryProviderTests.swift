import XCTest
@testable import WHOOPHealthSyncCore

@MainActor final class PrivateRecoveryProviderTests: XCTestCase {
    private let key = WhoopRecovery.pseudonymousAccountKey(userID: "123")
    private let start = Date(timeIntervalSince1970: 1_760_000_000)
    private func fixture(cycle: Int = 42, end: Date, updated: Date? = nil, seconds: Double = 0.047123456) -> [String: Any] {
        ["cycle": ["id": cycle, "user_id": 123],
         "recovery": ["user_id": 123, "activity_id": "sleep-\(cycle)", "hrv_rmssd": seconds, "state": "complete", "calibrating": false,
                      "updated_at": WhoopDateCodec.isoString(updated ?? end)],
         "sleeps": [["activity_id": "sleep-\(cycle)", "is_nap": false, "timezone_offset": "+02:00",
                     "during": "[\"\(WhoopDateCodec.isoString(end.addingTimeInterval(-8*3600)))\",\"\(WhoopDateCodec.isoString(end))\")"]]]
    }
    func testEmptyWindowsWalkToDeclaredStartAndNeverCertifyProviderExhaustion() async throws {
        var state = RecoverySyncState(); state.historyStartDate = start
        var windows: [TimeRange] = []
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, range in windows.append(range); return [] }, state: { state }, commitState: { state = $0 })
        let cutoff = start.addingTimeInterval(17*86400)
        var cursor: String?
        for index in 0..<3 {
            let page = try await provider.historicalPage(accountKey: key, cutoff: cutoff, cursor: cursor)
            XCTAssertFalse(page.endOfHistoryVerified)
            XCTAssertEqual(page.declaredScopeComplete, index == 2)
            cursor = page.nextCursor
        }
        XCTAssertNil(cursor); XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.last?.start, start)
        XCTAssertEqual(windows[0].start, windows[1].end)
    }
    func testSaturatedResponseShrinksWindowBeforeAdvancingCursor() async throws {
        var state = RecoverySyncState(); state.historyStartDate = start
        var calls: [TimeRange] = []
        let cutoff = start.addingTimeInterval(14*86400)
        let record = fixture(end: cutoff.addingTimeInterval(-3600))
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, range in
            calls.append(range); return calls.count == 1 ? Array(repeating: record, count: 50) : [record]
        }, state: { state }, commitState: { state = $0 })
        let page = try await provider.historicalPage(accountKey: key, cutoff: cutoff, cursor: nil)
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0].end, calls[1].end)
        XCTAssertEqual(calls[1].end.timeIntervalSince(calls[1].start), 3.5*86400)
        XCTAssertEqual(page.records.count, 1)
        _ = try await provider.historicalPage(accountKey: key, cutoff: cutoff, cursor: page.nextCursor)
        XCTAssertEqual(calls[2].end, calls[1].start)
    }
    func testSleepOutsideListingWindowIsPreservedWithinGlobalCutoff() async throws {
        var state = RecoverySyncState(); state.historyStartDate = start
        let cutoff = start.addingTimeInterval(14*86400)
        let record = fixture(end: cutoff.addingTimeInterval(-3600))
        var calls = 0
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, _ in calls += 1; return calls == 2 ? [record] : [] }, state: { state }, commitState: { state = $0 })
        let first = try await provider.historicalPage(accountKey: key, cutoff: cutoff, cursor: nil)
        let second = try await provider.historicalPage(accountKey: key, cutoff: cutoff, cursor: first.nextCursor)
        XCTAssertEqual(second.records.first?.representedDate, cutoff.addingTimeInterval(-3600))
    }
    func testCursorCanResumeInFreshProviderAndRejectsChangedAccountOrCutoff() async throws {
        var state = RecoverySyncState(); state.historyStartDate = start
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, _ in [] }, state: { state }, commitState: { state = $0 })
        let cutoff = start.addingTimeInterval(14*86400)
        let first = try await provider.historicalPage(accountKey: key, cutoff: cutoff, cursor: nil)
        let resumed = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, _ in [] }, state: { state }, commitState: { state = $0 })
        let resumedPage = try await resumed.historicalPage(accountKey: key, cutoff: cutoff, cursor: first.nextCursor)
        XCTAssertTrue(resumedPage.declaredScopeComplete)
        do { _ = try await resumed.historicalPage(accountKey: key, cutoff: cutoff.addingTimeInterval(1), cursor: first.nextCursor); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .cursorExpired) }
        do { _ = try await resumed.historicalPage(accountKey: "wrong", cutoff: cutoff, cursor: first.nextCursor); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .accountMismatch) }
    }
    func testRetryDeadlinePersistsAcrossProviderRecreationWithoutRequest() async throws {
        var state = RecoverySyncState(); state.historyStartDate = start
        let deadline = Date().addingTimeInterval(600)
        var requests = 0
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, _ in requests += 1; throw RecoverySyncError.rateLimited(until: deadline) }, state: { state }, commitState: { state = $0 })
        do { _ = try await provider.recentRecords(accountKey: key, window: TimeRange(start: start, end: start.addingTimeInterval(86400))); XCTFail() } catch {}
        XCTAssertEqual(state.providerRetryNotBefore, deadline)
        let resumed = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, _ in requests += 1; return [] }, state: { state }, commitState: { state = $0 })
        do { _ = try await resumed.recentRecords(accountKey: key, window: TimeRange(start: start, end: start.addingTimeInterval(86400))); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .rateLimited(until: deadline)) }
        XCTAssertEqual(requests, 1)
    }
    func testJournalOnlyRestartCanFindRecoveryByPersistedSleepAnchor() async throws {
        var state = RecoverySyncState(); state.historyStartDate = start
        let end = start.addingTimeInterval(86400)
        let identifier = "whoop-rmssd:\(key):42"
        let anchor = TimeRange(start: end.addingTimeInterval(-8*3600), end: end)
        state.pendingOperations[identifier] = RecoveryPendingOperation(identifier: identifier, fingerprint: "saved-before-crash", version: 1, sourceQueryRange: anchor)
        let payload = fixture(end: end)
        var queried: TimeRange?
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, window in queried = window; return [payload] }, state: { state }, commitState: { state = $0 })
        let restored = try await provider.recovery(accountKey: key, cycleID: "42")
        XCTAssertEqual(restored.identifier, identifier)
        XCTAssertLessThan(try XCTUnwrap(queried).start, anchor.start)
        XCTAssertTrue(state.records.isEmpty)
    }
    func testPathologicallyDenseRecentResponsesHaveBoundedRequestBudget() async throws {
        var state = RecoverySyncState(); state.historyStartDate = start
        let payload = fixture(end: start.addingTimeInterval(86400))
        var requests = 0
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, window in
            requests += 1
            return window.end.timeIntervalSince(window.start) > 100 ? Array(repeating: payload, count: 50) : []
        }, state: { state }, commitState: { state = $0 })
        do { _ = try await provider.recentRecords(accountKey: key, window: TimeRange(start: start, end: start.addingTimeInterval(7*86400))); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .providerContractUnverified) }
        XCTAssertLessThanOrEqual(requests, 128)
    }
    func testMissingRecoveryIsNotFabricatedAndForeignAccountIsRejected() async throws {
        var state = RecoverySyncState(); state.historyStartDate = start
        var payload: [[String: Any]] = [["cycle": ["id": 1, "user_id": 123], "recovery": NSNull()]]
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, _ in payload }, state: { state }, commitState: { state = $0 })
        let window = TimeRange(start: start, end: start.addingTimeInterval(86400))
        let empty = try await provider.recentRecords(accountKey: key, window: window)
        XCTAssertTrue(empty.isEmpty)
        payload = [["cycle": ["id": 1, "user_id": 456]]]
        do { _ = try await provider.recentRecords(accountKey: key, window: window); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .accountMismatch) }
    }
    func testOneUnverifiedNightDoesNotStopTheRestOfThePage() async throws {
        var state = RecoverySyncState(); state.historyStartDate = start
        let cutoff = start.addingTimeInterval(8*86400)
        let good = fixture(cycle: 7, end: cutoff.addingTimeInterval(-3600))
        var nap = fixture(cycle: 8, end: cutoff.addingTimeInterval(-2*3600))
        var sleep = nap["sleeps"] as! [[String: Any]]
        sleep[0]["is_nap"] = true
        nap["sleeps"] = sleep
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, _ in [good, nap] }, state: { state }, commitState: { state = $0 })
        let page = try await provider.historicalPage(accountKey: key, cutoff: cutoff, cursor: nil)
        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(page.records.first?.cycleID, "7")
        XCTAssertEqual(page.skippedUnverified, 1)
        XCTAssertNotNil(page.nextCursor)
    }
    func testDuplicateRecordsSelectLatestRevisionAndRejectConflictingEqualRevision() async throws {
        var state = RecoverySyncState(); state.historyStartDate = start
        let end = start.addingTimeInterval(86400)
        var payload = [fixture(end: end), fixture(end: end, updated: end.addingTimeInterval(3600), seconds: 0.05)]
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { "123" }, fetch: { _, _ in payload }, state: { state }, commitState: { state = $0 })
        let window = TimeRange(start: start, end: end)
        let latest = try await provider.recentRecords(accountKey: key, window: window)
        XCTAssertEqual(latest.count, 1); XCTAssertEqual(latest.first?.milliseconds, 50)
        payload = [fixture(end: end), fixture(end: end, seconds: 0.06)]
        do { _ = try await provider.recentRecords(accountKey: key, window: window); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .invalidRecord) }
    }
}
