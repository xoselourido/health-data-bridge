import XCTest
@testable import WHOOPHealthSyncCore

private let app = "com.joselourido.WHOOPHealthSync"
private let now = Date(timeIntervalSince1970: 1_789_430_400)
private func recovery(_ id: String = "42", daysAgo: Double = 1, value: Double? = 31.813562) -> WhoopRecovery {
    let end = now.addingTimeInterval(-daysAgo * 86400)
    return WhoopRecovery(accountKey: "account", cycleID: id, sleepID: "sleep-\(id)",
        sleepRange: TimeRange(start: end.addingTimeInterval(-28800), end: end), sourceTimeZoneID: "Europe/Madrid",
        milliseconds: value, scoreState: .scored, updatedAt: end)
}
private func own(_ item: WhoopRecovery, version: Int = 1) throws -> ExistingRecoverySample {
    ExistingRecoverySample(range: TimeRange(start: item.representedDate, end: item.representedDate), sourceBundle: app,
        identifier: item.identifier, fingerprint: try item.fingerprint(), version: version, recognizedMetadata: true)
}
final class RecoveryReconciliationTests: XCTestCase {
    private func plan(_ item: WhoopRecovery, samples: [ExistingRecoverySample] = [], access: HealthReadAccess = .externallyVisible,
                      local: RecoverySyncRecord? = nil, official: String? = nil) throws -> RecoveryDecision {
        try RecoveryReconciler.plan(recovery: item, local: local, samples: samples, access: access,
                                   appBundle: app, officialWhoopBundle: official)
    }
    func testT02ValidRealPrecisionAtSleepEnd() throws {
        let item = recovery(); XCTAssertEqual(item.representedDate, item.sleepRange.end)
        XCTAssertEqual(try plan(item), .write(fingerprint: try item.fingerprint(), version: 1))
        XCTAssertEqual(item.milliseconds, 31.813562)
    }
    func testT03SameVisibleIdentityUnchanged() throws {
        let item = recovery(); XCTAssertEqual(try plan(item, samples: [own(item)]), .unchanged(fingerprint: try item.fingerprint(), version: 1))
    }
    func testT04CorrectionUsesMaximumVersionPlusOne() throws {
        let old = recovery(); var revised = old; revised.milliseconds = 55; revised.updatedAt = now
        let local = RecoverySyncRecord(identifier: old.identifier, fingerprint: try old.fingerprint(), version: 8,
                                        sourceUpdatedAt: old.updatedAt, representedDate: old.representedDate)
        XCTAssertEqual(try plan(revised, samples: [own(old, version: 5)], local: local), .write(fingerprint: try revised.fingerprint(), version: 9))
        XCTAssertEqual(old.identifier, revised.identifier)
    }
    func testT05UpdatedAtAloneDoesNotChangeFingerprint() throws {
        let old = recovery(); var revised = old; revised.updatedAt = now
        XCTAssertEqual(try old.fingerprint(), try revised.fingerprint())
        XCTAssertEqual(try plan(revised, samples: [own(old)]), .unchanged(fingerprint: try old.fingerprint(), version: 1))
    }
    func testT06InvalidValuesNeverWritten() throws {
        for value in [nil, 0, -1, Double.infinity, -Double.infinity, Double.nan] as [Double?] {
            XCTAssertEqual(try plan(recovery(value: value)), .invalid)
        }
        var item = recovery(); item.userCalibrating = true; XCTAssertEqual(try plan(item), .invalid)
        item.scoreState = .pending; XCTAssertEqual(try plan(item), .pending)
        item.scoreState = .unscorable; XCTAssertEqual(try plan(item), .unscorable)
    }
    func testT07ExternalInstantaneousCoverageSkipsEntireRecovery() throws {
        let item = recovery(); let window = try item.coverageWindow()
        let external = ExistingRecoverySample(range: TimeRange(start: window.start, end: window.start), sourceBundle: "other.app")
        XCTAssertEqual(try plan(item, samples: [external]), .skippedExternal)
        let outside = ExistingRecoverySample(range: TimeRange(start: window.end, end: window.end), sourceBundle: "other.app")
        XCTAssertEqual(try plan(item, samples: [outside]), .write(fingerprint: try item.fingerprint(), version: 1))
    }
    func testT08SDNNNeverCoversRMSSD() throws {
        let item = recovery(); let sample = ExistingRecoverySample(range: item.sleepRange, sourceBundle: "apple", method: "SDNN")
        XCTAssertEqual(try plan(item, samples: [sample]), .write(fingerprint: try item.fingerprint(), version: 1))
    }
    func testT09ObservedNativeBundlePauses() throws {
        let item = recovery(); let external = ExistingRecoverySample(range: item.sleepRange, sourceBundle: "observed.native")
        XCTAssertEqual(try plan(item, samples: [external], official: "observed.native"), .pausedNativeExport)
    }
    func testT10BundleAndMetadataBothRequiredForOwnership() throws {
        let item = recovery(); var impostor = try own(item); impostor.sourceBundle = "com.joselourido.WHOOPHealthSync.copy"
        XCTAssertFalse(impostor.isOwned(appBundle: app)); XCTAssertEqual(try plan(item, samples: [impostor]), .skippedExternal)
        impostor.sourceBundle = app; impostor.recognizedMetadata = false; XCTAssertFalse(impostor.isOwned(appBundle: app))
    }
    func testT11T12WholeCoverageMustBeWithinBoundary() throws {
        let item = recovery(); let window = try item.coverageWindow()
        XCTAssertEqual(try plan(item, access: .limited(since: window.start.addingTimeInterval(1))), .deferredAccess)
        XCTAssertEqual(try plan(item, access: .limited(since: window.start)), .write(fingerprint: try item.fingerprint(), version: 1))
    }
    func testT13OwnSamplesDoNotProveReadAccess() throws {
        let item = recovery(); XCTAssertEqual(try plan(item, samples: [own(item)], access: .unknown), .deferredAccess)
    }
    func testT17LocalOnlyRecordDoesNotPretendHealthKitContainsSample() throws {
        let item = recovery(); let local = RecoverySyncRecord(identifier: item.identifier, fingerprint: try item.fingerprint(), version: 1,
            sourceUpdatedAt: item.updatedAt, representedDate: item.representedDate)
        XCTAssertEqual(try plan(item, local: local), .write(fingerprint: try item.fingerprint(), version: 2))
    }
    func testT21DSTSourceZoneAndMidnightStable() throws {
        var item = recovery(); item.sleepRange.end = ISO8601DateFormatter().date(from: "2026-03-29T06:00:00Z")!
        item.sleepRange.start = ISO8601DateFormatter().date(from: "2026-03-28T22:00:00Z")!
        let window = try item.coverageWindow()
        XCTAssertEqual(window.start, item.sleepRange.start)
        XCTAssertEqual(window.end, ISO8601DateFormatter().date(from: "2026-03-29T22:00:00Z")!)
        item.sourceTimeZoneID = "Invalid/Zone"; XCTAssertEqual(try plan(item), .invalid)
    }
    func testT25StateDoesNotPersistPhysiologicalValues() throws {
        let item = recovery(); var state = RecoverySyncState()
        state.records[item.identifier] = RecoverySyncRecord(identifier: item.identifier, fingerprint: try item.fingerprint(), version: 1,
            sourceUpdatedAt: item.updatedAt, representedDate: item.representedDate)
        let text = String(data: try JSONEncoder().encode(state), encoding: .utf8)!
        XCTAssertFalse(text.contains("31.813562")); XCTAssertFalse(text.contains("milliseconds"))
    }
    func testT31OldValidRecordIsNotPendingForThirtyDays() throws {
        XCTAssertNotNil(try recovery(daysAgo: 1800).fingerprint())
        let pending = RecoveryPendingItem(cycleID: "42", firstDetectedAt: now, reason: "pending_score")
        XCTAssertFalse(pending.requiresManualReview(at: now)); XCTAssertTrue(pending.requiresManualReview(at: now.addingTimeInterval(30 * 86400)))
    }
    func testT33TwentyDaysOfflineDoesNotLeaveThirteenDayGap() {
        var state = RecoverySyncState(); state.lastDiscoveryEnd = now.addingTimeInterval(-20 * 86400)
        XCTAssertEqual(state.recentWindow(now: now).start, state.lastDiscoveryEnd)
        state.lastDiscoveryEnd = now.addingTimeInterval(-2 * 86400)
        XCTAssertEqual(state.recentWindow(now: now).start, now.addingTimeInterval(-7 * 86400))
    }
    func testFingerprintDistinguishesEqualValuesAndAccounts() throws {
        let a = recovery("1"), b = recovery("2"); XCTAssertNotEqual(a.identifier, b.identifier); XCTAssertNotEqual(try a.fingerprint(), try b.fingerprint())
        var c = a; c.accountKey = "different"; XCTAssertNotEqual(a.identifier, c.identifier)
        XCTAssertEqual(WhoopRecovery.pseudonymousAccountKey(userID: "123").count, 64)
    }
    func testVersionOverflowFailsSafely() throws {
        let old = recovery(); var item = old; item.milliseconds = 50
        XCTAssertThrowsError(try plan(item, samples: [own(old, version: Int.max)]))
    }
    func testOlderSourceRevisionCannotReplaceNewerContent() throws {
        let item = recovery(); let local = RecoverySyncRecord(identifier: item.identifier, fingerprint: "newer", version: 5,
            sourceUpdatedAt: now, representedDate: item.representedDate)
        XCTAssertEqual(try plan(item, local: local), .invalid)
    }
}

@MainActor private final class MemoryState: RecoveryStatePersisting {
    var state = RecoverySyncState()
    var commitCount = 0
    var failCommitAt: Int?
    init() { state.enabled = true; state.configured = true; state.accountKey = "account" }
    func recoveryState() throws -> RecoverySyncState { state }
    func commitRecoveryState(_ candidate: RecoverySyncState) throws {
        commitCount += 1
        if failCommitAt == commitCount { throw TestFailure.disk }
        state = candidate
    }
}
private enum TestFailure: Error { case disk, network, save }
@MainActor private final class Provider: WhoopRecoveryProviding {
    var contractValidated = true
    var pages: [RecoveryPage] = []
    var recent: [WhoopRecovery] = []
    var individual: [String: WhoopRecovery] = [:]
    var individualErrors: [String: RecoverySyncError] = [:]
    var calls = 0, historicalCalls = 0, pendingCalls = 0
    var failPageAt: Int?
    var expireNextCursor = false
    var pageCursors: [String?] = []
    var cutoffs: [Date] = []
    var recentWindow: TimeRange?
    var onPage: (() -> Void)?
    func historicalPage(accountKey: String, cutoff: Date, cursor: String?) async throws -> RecoveryPage {
        calls += 1; historicalCalls += 1; pageCursors.append(cursor); cutoffs.append(cutoff)
        if historicalCalls == failPageAt { throw TestFailure.network }
        if cursor != nil && expireNextCursor { expireNextCursor = false; throw RecoverySyncError.cursorExpired }
        onPage?()
        let index = cursor.flatMap(Int.init) ?? 0
        return pages[index]
    }
    func recentRecords(accountKey: String, window: TimeRange) async throws -> [WhoopRecovery] {
        calls += 1; recentWindow = window; return recent
    }
    func recovery(accountKey: String, cycleID: String) async throws -> WhoopRecovery {
        calls += 1; pendingCalls += 1
        if let error = individualErrors[cycleID] { throw error }
        return individual[cycleID]!
    }
}
@MainActor private final class Health: RecoveryHealthProviding {
    var supported = true
    var access: HealthReadAccess = .externallyVisible
    var visible: [ExistingRecoverySample] = []
    var saves = 0, queries = 0, accessCalls = 0
    var failSave = false
    var onQuery: (() -> Void)?
    var onSave: (() -> Void)?
    func readAccess() async throws -> HealthReadAccess { accessCalls += 1; return access }
    func samples(in window: TimeRange, identifier: String) async throws -> [ExistingRecoverySample] {
        queries += 1; onQuery?(); return visible
    }
    func save(_ item: WhoopRecovery, fingerprint: String, version: Int) async throws {
        if failSave { throw TestFailure.save }
        saves += 1; visible.removeAll { $0.identifier == item.identifier && $0.isOwned(appBundle: app) }
        visible.append(try own(item, version: version)); onSave?()
    }
}
final class RecoveryPipelineTests: XCTestCase {
    @MainActor func testFixedCutoffSkipsFuturePendingAndDoesNotRewindRecentCheckpoint() async throws {
        let (s,p,h,e) = system()
        let future = recovery("future", daysAgo: -1)
        s.state.lastDiscoveryEnd = now.addingTimeInterval(3 * 86400)
        s.state.pendingItems[future.cycleID] = RecoveryPendingItem(cycleID: future.cycleID,
            firstDetectedAt: now, reason: "pending_score", range: future.sleepRange)
        p.individual[future.cycleID] = future; p.recent = [future]
        _ = try await e.run(accountKey: "account", mode: .recent, now: now)
        XCTAssertEqual(h.saves, 0)
        XCTAssertNotNil(s.state.pendingItems[future.cycleID])
        XCTAssertEqual(s.state.lastDiscoveryEnd, now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(p.recentWindow?.end, now)
    }

    @MainActor private func system() -> (MemoryState, Provider, Health, RecoverySyncPipeline) {
        let state = MemoryState(), provider = Provider(), health = Health()
        return (state, provider, health, RecoverySyncPipeline(provider: provider, health: health, persistence: state, appBundle: app))
    }
    @MainActor func testDeclaredScopeCompletionDoesNotClaimProviderCertifiedFullHistoryAndPublishesProgress() async throws {
        let (s,p,_,e) = system()
        s.state.historyScopeLimited = true
        p.pages = [RecoveryPage(records: [], nextCursor: "1", endOfHistoryVerified: false),
                   RecoveryPage(records: [recovery()], nextCursor: nil, endOfHistoryVerified: false, declaredScopeComplete: true)]
        var progress: [(Int, Bool)] = []
        e.progressChanged = { state, summary in progress.append((summary.pagesConfirmed, state.historyScopeLimited)) }
        let result = try await e.run(accountKey: "account", mode: .history, now: now)
        XCTAssertTrue(s.state.historicalResolved); XCTAssertFalse(result.historicalComplete)
        XCTAssertEqual(result.status, .historyLimited)
        XCTAssertEqual(progress.last?.0, 2); XCTAssertTrue(progress.allSatisfy { $0.1 })
    }
    @MainActor func testUnverifiedPendingNightDoesNotBlockCompletedHistory() async throws {
        let (s,p,h,e) = system()
        let bad = recovery("bad", daysAgo: 3)
        s.state.initialEnumerationComplete = true
        s.state.historyScopeLimited = true
        s.state.initialImportCutoff = now
        s.state.pendingItems[bad.cycleID] = RecoveryPendingItem(cycleID: bad.cycleID, firstDetectedAt: now, reason: "contract", range: bad.sleepRange)
        p.individualErrors[bad.cycleID] = .invalidTemporalAssociation
        let result = try await e.run(accountKey: "account", mode: .history, now: now)
        XCTAssertNil(s.state.pendingItems[bad.cycleID])
        XCTAssertTrue(s.state.historicalResolved)
        XCTAssertEqual(result.status, .historyLimited)
        XCTAssertEqual(result.invalid, 1)
        XCTAssertEqual(h.saves, 0)
    }
    @MainActor func testUnavailableJournalOnlyHistoricalRecoveryDoesNotStarveRecentDiscovery() async throws {
        let (s,p,h,e) = system()
        let missing = recovery("missing", daysAgo: 1000)
        s.state.pendingOperations[missing.identifier] = RecoveryPendingOperation(identifier: missing.identifier, fingerprint: "uncommitted", version: 1, sourceQueryRange: missing.sleepRange)
        p.individualErrors[missing.cycleID] = .invalidRecord; p.recent = [recovery("new")]
        let result = try await e.run(accountKey: "account", mode: .recent, now: now)
        XCTAssertTrue(result.recentCompleted); XCTAssertFalse(result.historicalComplete)
        XCTAssertEqual(h.saves, 1); XCTAssertEqual(p.pendingCalls, 1)
        XCTAssertNotNil(s.state.pendingOperations[missing.identifier])
        XCTAssertEqual(s.state.pendingItems[missing.cycleID]?.range, missing.sleepRange)
        XCTAssertEqual(s.state.pendingItems[missing.cycleID]?.firstDetectedAt, now)
        XCTAssertEqual(s.state.lastDiscoveryEnd, now)
    }
    @MainActor func testPendingAccountMismatchStillBlocksRecentWrites() async {
        let (s,p,h,e) = system()
        let missing = recovery("missing", daysAgo: 1000)
        s.state.pendingItems[missing.cycleID] = RecoveryPendingItem(cycleID: missing.cycleID, firstDetectedAt: now, reason: "access", range: missing.sleepRange)
        p.individualErrors[missing.cycleID] = .accountMismatch; p.recent = [recovery("new")]
        do { _ = try await e.run(accountKey: "account", mode: .recent, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .accountMismatch) }
        XCTAssertEqual(h.saves, 0); XCTAssertNil(s.state.lastDiscoveryEnd)
    }
    @MainActor func testFailedPageCommitNeverPublishesAnUnconfirmedPage() async {
        let (s,p,_,e) = system(); s.failCommitAt = 2
        p.pages = [RecoveryPage(records: [], nextCursor: nil, endOfHistoryVerified: true)]
        do { _ = try await e.run(accountKey: "account", mode: .history, now: now); XCTFail() } catch {}
        XCTAssertEqual(s.state.historicalPagesConfirmed, 0)
        XCTAssertEqual(e.lastSummary.pagesConfirmed, 0)
    }
    @MainActor func testHistoricalCutoffUsesPersistentSecondPrecisionBeforeGeneratingCursor() async throws {
        let (s,p,_,e) = system()
        p.pages = [RecoveryPage(records: [], nextCursor: "1", endOfHistoryVerified: false)]
        let fractionalNow = now.addingTimeInterval(0.345)
        _ = try await e.run(accountKey: "account", mode: .history, now: fractionalNow, maxPages: 1)
        XCTAssertEqual(s.state.initialImportCutoff, now)
        XCTAssertEqual(p.cutoffs.first, now)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(RecoverySyncState.self, from: encoder.encode(s.state))
        XCTAssertEqual(restored.initialImportCutoff, p.cutoffs.first)
    }
    @MainActor func testVisibleNativeExporterPausesBeforeProviderCalls() async throws {
        let (s,p,h,e) = system(); h.access = .nativeExporter(bundle: "com.whoop.native")
        let result = try await e.run(accountKey: "account", mode: .history, now: now)
        XCTAssertEqual(result.status, .pausedNativeExport); XCTAssertEqual(p.calls, 0); XCTAssertEqual(h.saves, 0)
        XCTAssertEqual(s.state.officialWhoopBundle, "com.whoop.native"); XCTAssertTrue(s.state.pausedForNativeExport)
    }
    @MainActor func testExplicitReadingConfirmationAllowsOwnOnlyReconciliationAndJournalKeepsSleepAnchor() async throws {
        let (s,p,h,e) = system(); p.recent = [recovery()]; h.access = .userConfirmedFullAccess; h.failSave = true
        do { _ = try await e.run(accountKey: "account", mode: .recent, now: now); XCTFail() } catch {}
        XCTAssertEqual(s.state.pendingOperations[recovery().identifier]?.sourceQueryRange, recovery().sleepRange)
        XCTAssertEqual(s.state.records.count, 0)
    }
    @MainActor func testLogoutAndBackgroundStopBeforeWriting() async {
        for stopForLogout in [true, false] {
            let s = MemoryState(), p = Provider(), h = Health()
            p.pages = [RecoveryPage(records: [recovery()], nextCursor: nil, endOfHistoryVerified: true)]
            var active = true
            let e = RecoverySyncPipeline(provider: p, health: h, persistence: s, appBundle: app,
                canContinueHistory: { stopForLogout || active }, canContinueSync: { !stopForLogout || active })
            p.onPage = { active = false }
            do { _ = try await e.run(accountKey: "account", mode: .history, now: now); XCTFail() }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(h.saves, 0); XCTAssertEqual(s.state.historicalPagesConfirmed, 0)
        }
    }
    @MainActor func testT01DisabledHasZeroRecoveryOrPermissionCalls() async throws {
        let (s,p,h,e) = system(); s.state.enabled = false
        let result = try await e.run(accountKey: "account", mode: .history, now: now)
        XCTAssertEqual(result.status, .disabled); XCTAssertEqual(p.calls, 0); XCTAssertEqual(h.accessCalls, 0); XCTAssertEqual(h.saves, 0)
    }
    @MainActor func testT01UnsupportedHasZeroRecoveryCalls() async throws {
        let (_,p,h,e) = system(); h.supported = false
        let result = try await e.run(accountKey: "account", mode: .recent, now: now)
        XCTAssertEqual(result.status, .requiresIOS27); XCTAssertEqual(p.calls, 0); XCTAssertEqual(h.accessCalls, 0)
    }
    @MainActor func testT23UnconfiguredNeverRequestsPermissionsOrRecovery() async throws {
        let (s,p,h,e) = system(); s.state.configured = false
        let result = try await e.run(accountKey: "account", mode: .recent, now: now)
        XCTAssertEqual(result.status, .configurationPending); XCTAssertEqual(p.calls, 0); XCTAssertEqual(h.saves, 0)
    }
    @MainActor func testG2UnvalidatedContractBlocksAllCalls() async {
        let (_,p,h,e) = system(); p.contractValidated = false
        do { _ = try await e.run(accountKey: "account", mode: .history, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .providerContractUnverified) }
        XCTAssertEqual(p.calls, 0); XCTAssertEqual(h.saves, 0)
    }
    @MainActor func testT13UnknownVisibilityDoesNotAdvance() async throws {
        let (s,p,h,e) = system(); h.access = .unknown
        let result = try await e.run(accountKey: "account", mode: .recent, now: now)
        XCTAssertEqual(result.status, .readUnverified); XCTAssertNil(s.state.lastDiscoveryEnd); XCTAssertEqual(p.calls, 0)
    }
    @MainActor func testT03RepeatedRecentSyncWritesOnce() async throws {
        let (_,p,h,e) = system(); p.recent = [recovery()]
        _ = try await e.run(accountKey: "account", mode: .recent, now: now)
        let repeatResult = try await e.run(accountKey: "account", mode: .recent, now: now)
        XCTAssertEqual(h.saves, 1); XCTAssertEqual(repeatResult.written, 0); XCTAssertEqual(repeatResult.unchanged, 1)
    }
    @MainActor func testT14RevocationBeforeSaveDoesNotWrite() async throws {
        let (s,p,h,e) = system(); p.recent = [recovery()]
        h.onQuery = { if h.queries == 1 { h.access = .unknown } }
        let result = try await e.run(accountKey: "account", mode: .recent, now: now)
        XCTAssertEqual(h.saves, 0); XCTAssertEqual(result.deferredAccess, 1); XCTAssertFalse(s.state.historicalResolved)
    }
    @MainActor func testT15FailedLastPageRetainsConfirmedCursor() async {
        let (s,p,h,e) = system(); p.pages = [RecoveryPage(records: [recovery()], nextCursor: "1", endOfHistoryVerified: false)]
        p.failPageAt = 2
        do { _ = try await e.run(accountKey: "account", mode: .history, now: now); XCTFail() } catch {}
        XCTAssertEqual(s.state.historicalCursor, "1"); XCTAssertEqual(s.state.historicalPagesConfirmed, 1)
        XCTAssertFalse(s.state.initialEnumerationComplete); XCTAssertEqual(h.saves, 1)
    }
    @MainActor func testT15RepeatedCursorDoesNotDeclareComplete() async {
        let (s,p,_,e) = system(); p.pages = [RecoveryPage(records: [], nextCursor: "0", endOfHistoryVerified: false)]
        do { _ = try await e.run(accountKey: "account", mode: .history, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .repeatedCursor) }
        XCTAssertFalse(s.state.initialEnumerationComplete)
    }
    @MainActor func testT17CrashAfterHealthSaveBeforeCommitReconcilesWithoutDuplicate() async throws {
        let (s,p,h,e) = system(); let item = recovery(); p.recent = [item]; p.individual[item.cycleID] = item
        s.failCommitAt = 2 // journal saved, HealthKit saved, local record commit fails
        do { _ = try await e.run(accountKey: "account", mode: .recent, now: now); XCTFail() } catch {}
        XCTAssertEqual(h.saves, 1); XCTAssertEqual(s.state.pendingOperations.count, 1); XCTAssertNil(s.state.lastDiscoveryEnd)
        s.failCommitAt = nil
        let result = try await e.run(accountKey: "account", mode: .recent, now: now)
        XCTAssertEqual(h.saves, 1); XCTAssertEqual(result.unchanged, 1); XCTAssertTrue(s.state.pendingOperations.isEmpty)
    }
    @MainActor func testT18JournalDiskFailurePreventsHealthSave() async {
        let (s,p,h,e) = system(); p.recent = [recovery()]; s.failCommitAt = 1
        do { _ = try await e.run(accountKey: "account", mode: .recent, now: now); XCTFail() } catch {}
        XCTAssertEqual(h.saves, 0); XCTAssertNil(s.state.lastDiscoveryEnd); XCTAssertTrue(s.state.records.isEmpty)
    }
    @MainActor func testSaveFailureKeepsDurableOperationAndNoProgress() async {
        let (s,p,h,e) = system(); p.recent = [recovery()]; h.failSave = true
        do { _ = try await e.run(accountKey: "account", mode: .recent, now: now); XCTFail() } catch {}
        XCTAssertEqual(s.state.pendingOperations.count, 1); XCTAssertNil(s.state.lastDiscoveryEnd); XCTAssertEqual(e.lastSummary.written, 0)
    }
    @MainActor func testT20DifferentAccountCannotUseCheckpoints() async {
        let (_,p,h,e) = system()
        do { _ = try await e.run(accountKey: "foreign", mode: .recent, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .accountMismatch) }
        XCTAssertEqual(p.calls, 0); XCTAssertEqual(h.saves, 0)
    }
    @MainActor func testT24DisabledDuringQueryStopsBeforeNextWrite() async {
        let (s,p,h,e) = system(); p.recent = [recovery()]; h.onQuery = { s.state.enabled = false }
        do { _ = try await e.run(accountKey: "account", mode: .recent, now: now); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(h.saves, 0); XCTAssertFalse(s.state.enabled); XCTAssertNil(s.state.lastDiscoveryEnd)
    }
    @MainActor func testT24DisableWhileSaveInFlightPreservesConfirmedWriteButStopsNext() async {
        let (s,p,h,e) = system(); p.recent = [recovery("1"), recovery("2")]
        h.onSave = { s.state.enabled = false }
        do { _ = try await e.run(accountKey: "account", mode: .recent, now: now); XCTFail() } catch {}
        XCTAssertEqual(h.saves, 1); XCTAssertFalse(s.state.enabled); XCTAssertEqual(s.state.records.count, 1); XCTAssertNil(s.state.lastDiscoveryEnd)
    }
    @MainActor func testT29MultipleYearsAllPagesImported() async throws {
        let (s,p,h,e) = system()
        for index in 0..<5 {
            let item = recovery(String(index), daysAgo: Double(index * 365 + 1))
            let next: String? = index == 4 ? nil : String(index + 1)
            p.pages.append(RecoveryPage(records: [item], nextCursor: next, endOfHistoryVerified: index == 4))
        }
        let result = try await e.run(accountKey: "account", mode: .history, now: now)
        XCTAssertEqual(h.saves, 5); XCTAssertEqual(s.state.historicalPagesConfirmed, 5); XCTAssertTrue(result.historicalComplete)
        XCTAssertEqual(s.state.oldestEnumeratedDate, recovery("4", daysAgo: 1461).representedDate)
    }
    @MainActor func testT30ResumeConfirmedPageWithoutDuplicate() async throws {
        let (s,p,h,e) = system()
        p.pages = [RecoveryPage(records: [recovery("1")], nextCursor: "1", endOfHistoryVerified: false),
                   RecoveryPage(records: [recovery("2", daysAgo: 1000)], nextCursor: nil, endOfHistoryVerified: true)]
        let first = try await e.run(accountKey: "account", mode: .history, now: now, maxPages: 1)
        XCTAssertFalse(first.historicalComplete); XCTAssertEqual(s.state.historicalCursor, "1")
        let second = try await e.run(accountKey: "account", mode: .history, now: now.addingTimeInterval(86400))
        XCTAssertTrue(second.historicalComplete); XCTAssertEqual(h.saves, 2); XCTAssertEqual(p.cutoffs, [now, now])
    }
    @MainActor func testT32NewRecordsDoNotMoveInitialCutoff() async throws {
        let (s,p,h,e) = system(); let future = recovery("new", daysAgo: -1)
        p.pages = [RecoveryPage(records: [recovery("old"), future], nextCursor: nil, endOfHistoryVerified: true)]
        _ = try await e.run(accountKey: "account", mode: .history, now: now)
        XCTAssertEqual(h.saves, 1); XCTAssertEqual(s.state.initialImportCutoff, now)
        p.recent = [future]
        _ = try await e.run(accountKey: "account", mode: .recent, now: now.addingTimeInterval(2 * 86400))
        XCTAssertEqual(h.saves, 2)
    }
    @MainActor func testT34LimitedHistoryReplaysDeferredRecordWhenAccessExpands() async throws {
        let (s,p,h,e) = system(); let old = recovery("old", daysAgo: 1000)
        p.pages = [RecoveryPage(records: [old], nextCursor: nil, endOfHistoryVerified: true)]
        p.individual[old.cycleID] = old; h.access = .limited(since: now.addingTimeInterval(-7 * 86400))
        let first = try await e.run(accountKey: "account", mode: .history, now: now)
        XCTAssertFalse(first.historicalComplete); XCTAssertTrue(s.state.initialEnumerationComplete); XCTAssertEqual(first.deferredAccess, 1)
        h.access = .externallyVisible
        let second = try await e.run(accountKey: "account", mode: .history, now: now)
        XCTAssertTrue(second.historicalComplete); XCTAssertEqual(h.saves, 1); XCTAssertEqual(p.historicalCalls, 1)
    }
    @MainActor func testT35EmptyPageWithoutVerifiedEndDoesNotCompleteHistory() async {
        let (s,p,_,e) = system(); p.pages = [RecoveryPage(records: [], nextCursor: nil, endOfHistoryVerified: false)]
        do { _ = try await e.run(accountKey: "account", mode: .history, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RecoverySyncError, .unknownHistoryEnd) }
        XCTAssertFalse(s.state.initialEnumerationComplete); XCTAssertEqual(s.state.historicalPagesConfirmed, 0)
    }
    @MainActor func testT36ShortcutRecentDoesNotLaunchOrCompleteOldHistory() async throws {
        let (s,p,h,e) = system(); s.state.initialImportCutoff = now.addingTimeInterval(-20 * 86400)
        s.state.historicalCursor = "resume"; p.recent = [recovery()]
        let result = try await e.run(accountKey: "account", mode: .recent, now: now)
        XCTAssertEqual(p.historicalCalls, 0); XCTAssertFalse(result.historicalComplete); XCTAssertEqual(s.state.historicalCursor, "resume")
        XCTAssertEqual(p.recentWindow?.start, s.state.initialImportCutoff); XCTAssertEqual(h.saves, 1)
    }
    @MainActor func testT35ExpiredCursorRestartsFixedCutoffWithoutDuplicates() async throws {
        let (s,p,h,e) = system()
        p.pages = [RecoveryPage(records: [recovery("1")], nextCursor: "1", endOfHistoryVerified: false),
                   RecoveryPage(records: [recovery("2", daysAgo: 1000)], nextCursor: nil, endOfHistoryVerified: true)]
        _ = try await e.run(accountKey: "account", mode: .history, now: now, maxPages: 1)
        p.expireNextCursor = true
        let expired = try await e.run(accountKey: "account", mode: .history, now: now.addingTimeInterval(86400))
        XCTAssertEqual(expired.status, .historyPending); XCTAssertNil(s.state.historicalCursor)
        let resumed = try await e.run(accountKey: "account", mode: .history, now: now.addingTimeInterval(2 * 86400))
        XCTAssertTrue(resumed.historicalComplete); XCTAssertEqual(h.saves, 2)
        XCTAssertTrue(p.cutoffs.allSatisfy { $0 == now })
    }
    @MainActor func testT24CancelledTaskNeverDownloadsOrWrites() async {
        let (s,p,h,e) = system()
        let task = Task { @MainActor in
            _ = try await e.run(accountKey: "account", mode: .recent, now: now)
        }
        task.cancel()
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(p.calls, 0); XCTAssertEqual(h.saves, 0); XCTAssertNil(s.state.lastDiscoveryEnd)
    }
    @MainActor func testPendingRetriedOncePerExecutionAndKeptBeyondWindow() async throws {
        let (s,p,_,e) = system(); var pending = recovery(); pending.scoreState = .pending
        p.recent = [pending]; p.individual[pending.cycleID] = pending
        _ = try await e.run(accountKey: "account", mode: .recent, now: now)
        _ = try await e.run(accountKey: "account", mode: .recent, now: now.addingTimeInterval(10 * 86400))
        XCTAssertEqual(p.pendingCalls, 1); XCTAssertEqual(s.state.pendingItems.count, 1)
        _ = try await e.run(accountKey: "account", mode: .recent, now: now.addingTimeInterval(31 * 86400))
        XCTAssertEqual(p.pendingCalls, 1); XCTAssertEqual(s.state.pendingItems.count, 1)
    }
}

final class RecoveryContractTests: XCTestCase {
    private func sleep(nap: Bool = false) -> SleepSession {
        SleepSession(whoopSleepID: "sleep-1", sourceUpdatedAt: nil, start: now.addingTimeInterval(-28800),
                     end: now, timezoneOffsetSeconds: 7200, isNap: nap, stages: [])
    }
    private func json(value: String = "31.813562", state: String = "SCORED", user: Int = 123) -> Data {
        Data("{\"cycle_id\":1,\"sleep_id\":\"sleep-1\",\"user_id\":\(user),\"updated_at\":\"2026-09-15T08:00:00Z\",\"score_state\":\"\(state)\",\"score\":{\"user_calibrating\":false,\"hrv_rmssd_milli\":\(value)}}".utf8)
    }
    func testT02DocumentedReferencePreservesPrecisionAndAssociation() throws {
        let item = try WhoopRecoveryReferenceAdapter.decode(json(), expectedUserID: "123", sleep: sleep(), sourceTimeZoneID: "Europe/Madrid")
        XCTAssertEqual(item.milliseconds, 31.813562); XCTAssertEqual(item.sleepID, "sleep-1")
        XCTAssertEqual(item.accountKey, WhoopRecovery.pseudonymousAccountKey(userID: "123"))
        XCTAssertEqual(item.representedDate, sleep().end)
    }
    func testT06NullIsNotConvertedToZero() throws {
        let item = try WhoopRecoveryReferenceAdapter.decode(json(value: "null"), expectedUserID: "123", sleep: sleep(), sourceTimeZoneID: "Europe/Madrid")
        XCTAssertNil(item.milliseconds); XCTAssertThrowsError(try item.fingerprint())
    }
    func testT06UnknownContractAndWrongTypeRejected() {
        XCTAssertThrowsError(try WhoopRecoveryReferenceAdapter.decode(json(value: "\"31.8\""), expectedUserID: "123", sleep: sleep(), sourceTimeZoneID: "Europe/Madrid"))
        XCTAssertThrowsError(try WhoopRecoveryReferenceAdapter.decode(json(state: "UNKNOWN"), expectedUserID: "123", sleep: sleep(), sourceTimeZoneID: "Europe/Madrid"))
    }
    func testT20WrongProviderUserRejected() {
        XCTAssertThrowsError(try WhoopRecoveryReferenceAdapter.decode(json(user: 456), expectedUserID: "123", sleep: sleep(), sourceTimeZoneID: "Europe/Madrid"))
    }
    func testT21NapCannotBeUsedAsMainSleep() {
        XCTAssertThrowsError(try WhoopRecoveryReferenceAdapter.decode(json(), expectedUserID: "123", sleep: sleep(nap: true), sourceTimeZoneID: "Europe/Madrid"))
    }
    func testV2StateAbsentFieldsDecodeConservatively() throws {
        let state = try JSONDecoder().decode(RecoverySyncState.self, from: Data("{}".utf8))
        XCTAssertFalse(state.enabled); XCTAssertFalse(state.configured); XCTAssertFalse(state.historicalResolved)
    }
}
final class RecoveryProbeTests: XCTestCase {
    func testT25SchemaProbeCannotExposeScalarValuesOrSensitiveKeyNames() {
        let object: [String: Any] = ["hrv_rmssd_milli": 67.123, "email": "private@example.com", "token": "secret-token",
            "private@example.com": "secret", "recovery": ["score_state": "SCORED", "cycle_id": 99999999]]
        let text = WhoopContractProbe.schema(of: object)
        XCTAssertTrue(text.contains("hrv_rmssd_milli")); XCTAssertTrue(text.contains("cycle_id"))
        for secret in ["67.123", "private@example.com", "secret-token", "SCORED", "99999999"] {
            XCTAssertFalse(text.contains(secret))
        }
    }
    func testSchemaProbeHasBoundedOutputForLargePayloads() {
        let object = Dictionary(uniqueKeysWithValues: (0..<10000).map { ("field_\($0)", $0) })
        XCTAssertLessThanOrEqual(WhoopContractProbe.schema(of: object, maxEntries: 20).split(separator: "\n").count, 20)
    }
}
