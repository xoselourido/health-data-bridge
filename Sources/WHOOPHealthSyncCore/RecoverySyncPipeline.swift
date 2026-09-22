import Foundation
import CryptoKit

public struct RecoveryPage: Sendable {
    public var records: [WhoopRecovery]
    public var nextCursor: String?
    /// Must come from a validated provider signal, never inferred from an empty list.
    public var endOfHistoryVerified: Bool
    public var declaredScopeComplete: Bool
    /// Cycles in this page that could not be placed on a sleep or time zone. The page still advances.
    public var skippedUnverified: Int
    public init(records: [WhoopRecovery], nextCursor: String?, endOfHistoryVerified: Bool, declaredScopeComplete: Bool = false, skippedUnverified: Int = 0) {
        self.records = records; self.nextCursor = nextCursor; self.endOfHistoryVerified = endOfHistoryVerified
        self.declaredScopeComplete = declaredScopeComplete; self.skippedUnverified = skippedUnverified
    }
}
@MainActor public protocol WhoopRecoveryProviding {
    var contractValidated: Bool { get }
    func historicalPage(accountKey: String, cutoff: Date, cursor: String?) async throws -> RecoveryPage
    func recentRecords(accountKey: String, window: TimeRange) async throws -> [WhoopRecovery]
    func recovery(accountKey: String, cycleID: String) async throws -> WhoopRecovery
}
@MainActor public protocol RecoveryHealthProviding {
    var supported: Bool { get }
    func readAccess() async throws -> HealthReadAccess
    func samples(in window: TimeRange, identifier: String) async throws -> [ExistingRecoverySample]
    func save(_ recovery: WhoopRecovery, fingerprint: String, version: Int) async throws
}
@MainActor public protocol RecoveryStatePersisting {
    func recoveryState() throws -> RecoverySyncState
    func commitRecoveryState(_ state: RecoverySyncState) throws
    func prepareRecoveryOperation(_ operation: RecoveryPendingOperation) throws
}
public extension RecoveryStatePersisting {
    func prepareRecoveryOperation(_ operation: RecoveryPendingOperation) throws {
        var state = try recoveryState(); state.pendingOperations[operation.identifier] = operation
        try commitRecoveryState(state)
    }
}
public enum RecoveryRunMode: Sendable { case recent, history }

/// Serial, bounded pages with a durable write-ahead journal and fixed historical cutoff.
@MainActor public final class RecoverySyncPipeline {
    private let provider: any WhoopRecoveryProviding
    private let health: any RecoveryHealthProviding
    private let persistence: any RecoveryStatePersisting
    private let appBundle: String
    public var progressChanged: (@MainActor (RecoverySyncState, RecoverySyncSummary) -> Void)?
    private var running = false
    private var mode: RecoveryRunMode = .recent
    private let canContinueSync: @MainActor () -> Bool
    private let canContinueHistory: @MainActor () -> Bool
    public private(set) var lastSummary = RecoverySyncSummary()
    public init(provider: any WhoopRecoveryProviding, health: any RecoveryHealthProviding,
                persistence: any RecoveryStatePersisting, appBundle: String, canContinueHistory: @escaping @MainActor () -> Bool = { true }, canContinueSync: @escaping @MainActor () -> Bool = { true }) {
        self.canContinueSync = canContinueSync
        self.canContinueHistory = canContinueHistory
        self.provider = provider; self.health = health; self.persistence = persistence; self.appBundle = appBundle
    }
    public func run(accountKey: String, mode: RecoveryRunMode, now: Date = Date(),
                    maxPages: Int = 20) async throws -> RecoverySyncSummary {
        guard !running else { throw RecoverySyncError.unavailable }
        self.mode = mode
        running = true; defer { running = false }
        lastSummary = RecoverySyncSummary()
        var state = try persistence.recoveryState()
        guard state.enabled else { return lastSummary }
        guard health.supported else { lastSummary.status = .requiresIOS27; return lastSummary }
        guard state.configured else { lastSummary.status = .configurationPending; return lastSummary }
        guard state.accountKey == accountKey else { throw RecoverySyncError.accountMismatch }
        guard provider.contractValidated else { throw RecoverySyncError.providerContractUnverified }
        guard !state.pausedForNativeExport else { lastSummary.status = .pausedNativeExport; return lastSummary }
        try Task.checkCancellation()
        let access = try await health.readAccess()
        if case let .nativeExporter(bundle) = access {
            state.officialWhoopBundle = bundle; state.pausedForNativeExport = true
            try commitProgress(&state); lastSummary.status = .pausedNativeExport; return lastSummary
        }
        guard access != .unknown else { lastSummary.status = .readUnverified; return lastSummary }
        if mode == .history && state.initialImportCutoff == nil {
            // The repository persists ISO timestamps at second precision. Keep cursor and persisted cutoff identical on restart.
            state.initialImportCutoff = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
            try commitProgress(&state)
        }
        var seen = Set<String>()
        // Resolve each persisted pending ID at most once per execution, including journal-only crash recovery.
        let pendingIDs = Set(state.pendingItems.keys).union(state.pendingOperations.keys.compactMap { id in
            state.records[id]?.identifier == id ? nil : id.split(separator: ":").last.map(String.init)
        })
        for cycleID in pendingIDs.sorted() {
            if state.pendingItems[cycleID]?.requiresManualReview(at: now) == true { continue }
            try await checkActive(accountKey: accountKey)
            let item: WhoopRecovery
            do { item = try await provider.recovery(accountKey: accountKey, cycleID: cycleID) }
            catch let error as RecoverySyncError {
                switch error {
                case .invalidRecord, .invalidTemporalAssociation, .providerContractUnverified:
                    // A missing/changed historical record must not starve discovery of valid recent data.
                    // Retain the WAL: a previous HealthKit save may still need reconciliation.
                    // Without a journal, the night cannot be written and must not keep the import unfinished.
                    let identifier = "whoop-rmssd:\(accountKey):\(cycleID)"
                    let pending = state.pendingItems[cycleID]
                    let range = pending?.range ?? state.pendingOperations[identifier]?.sourceQueryRange
                    if state.pendingOperations[identifier] != nil {
                        state.pendingItems[cycleID] = RecoveryPendingItem(cycleID: cycleID,
                            firstDetectedAt: pending?.firstDetectedAt ?? now, reason: "contract", range: range)
                    } else {
                        state.pendingItems.removeValue(forKey: cycleID)
                    }
                    lastSummary.invalid += 1
                    try commitProgress(&state)
                    continue
                default: throw error
                }
            }
            // A resumed explicit import must not write new records beyond its fixed cutoff.
            guard item.representedDate <= now else { continue }
            try await processBatch([item], state: &state, access: access, now: now)
            seen.insert(item.identifier)
            if state.pausedForNativeExport { return lastSummary }
        }
        if mode == .recent {
            let window = state.recentWindow(now: now)
            let records = try await provider.recentRecords(accountKey: accountKey, window: window)
            let eligible = records.filter { $0.representedDate >= window.start && $0.representedDate <= window.end && seen.insert($0.identifier).inserted }
            for offset in stride(from: 0, to: eligible.count, by: 32) {
                try await processBatch(Array(eligible[offset..<min(offset + 32, eligible.count)]), state: &state, access: access, now: now)
                if state.pausedForNativeExport { return lastSummary }
            }
            try await checkActive(accountKey: accountKey)
            state.lastDiscoveryEnd = max(state.lastDiscoveryEnd ?? now, now)
            try commitProgress(&state)
            lastSummary.recentCompleted = true
        } else if !state.initialEnumerationComplete {
            lastSummary.status = .importingHistory
            let cutoff = state.initialImportCutoff!
            var cursors = Set<String>()
            if let cursor = state.historicalCursor { cursors.insert(cursor) }
            for _ in 0..<max(0, maxPages) {
                try await checkActive(accountKey: accountKey)
                let page: RecoveryPage
                do {
                    page = try await provider.historicalPage(accountKey: accountKey, cutoff: cutoff, cursor: state.historicalCursor)
                } catch RecoverySyncError.cursorExpired {
                    // Exhaustive restart is conservative when a provider has no stable-position resume API.
                    // Keep the fixed cutoff, records and pending work; HealthKit reconciliation prevents duplicates.
                    state.historicalCursor = nil
                    state.confirmedCursorFingerprints = []
                    try commitProgress(&state)
                    lastSummary.status = .historyPending
                    return lastSummary
                }
                if let next = page.nextCursor, next.isEmpty || cursors.contains(next)
                    || state.confirmedCursorFingerprints.contains(Self.cursorFingerprint(next)) {
                    throw RecoverySyncError.repeatedCursor
                }
                guard page.nextCursor != nil || page.endOfHistoryVerified || page.declaredScopeComplete else {
                    throw RecoverySyncError.unknownHistoryEnd
                }
                guard !((page.endOfHistoryVerified || page.declaredScopeComplete) && page.nextCursor != nil) else {
                    throw RecoverySyncError.unknownHistoryEnd
                }
                lastSummary.invalid += page.skippedUnverified
                let eligible = page.records.filter { $0.representedDate <= cutoff && seen.insert($0.identifier).inserted }
                for offset in stride(from: 0, to: eligible.count, by: 32) {
                    let batch = Array(eligible[offset..<min(offset + 32, eligible.count)])
                    try await processBatch(batch, state: &state, access: access, now: now)
                    if state.pausedForNativeExport { return lastSummary }
                    for item in batch {
                        state.oldestEnumeratedDate = min(state.oldestEnumeratedDate ?? item.representedDate, item.representedDate)
                    }
                }
                try await checkActive(accountKey: accountKey)
                if let previous = state.historicalCursor { state.confirmedCursorFingerprints.insert(Self.cursorFingerprint(previous)) }
                state.historicalCursor = page.nextCursor
                state.historicalPagesConfirmed += 1
                state.initialEnumerationComplete = page.endOfHistoryVerified || page.declaredScopeComplete
                if state.initialEnumerationComplete { state.historyScopeLimited = page.declaredScopeComplete }
                lastSummary.pagesConfirmed += 1
                do { try commitProgress(&state) }
                catch { lastSummary.pagesConfirmed -= 1; throw error }
                if let next = page.nextCursor { cursors.insert(next) }
                if state.initialEnumerationComplete { break }
            }
        }
        lastSummary.historicalComplete = state.historicalResolved && !state.historyScopeLimited
        lastSummary.status = state.historicalResolved || mode == .recent ? .completed : .historyPending
        if !state.pendingItems.isEmpty {
            lastSummary.status = state.pendingItems.values.contains { $0.reason == "access" } ? .historyLimited : .historyPending
        }
        if state.historyScopeLimited && state.historicalResolved { lastSummary.status = .historyLimited }
        progressChanged?(state, lastSummary)
        return lastSummary
    }
    private static func cursorFingerprint(_ cursor: String) -> String {
        SHA256.hash(data: Data(cursor.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func commitProgress(_ state: inout RecoverySyncState) throws {
        let current = try persistence.recoveryState()
        guard current.accountKey == state.accountKey else { throw RecoverySyncError.accountMismatch }
        state.enabled = current.enabled
        state.configured = current.configured
        state.userConfirmedFullReadAccess = current.userConfirmedFullReadAccess
        state.providerRetryNotBefore = current.providerRetryNotBefore
        try persistence.commitRecoveryState(state)
        progressChanged?(state, lastSummary)
    }
    private func checkActive(accountKey: String) async throws {
        try Task.checkCancellation()
        if !canContinueSync() { throw CancellationError() }
        if mode == .history && !canContinueHistory() { throw CancellationError() }
        let current = try persistence.recoveryState()
        guard current.enabled else { throw CancellationError() }
        guard current.accountKey == accountKey else { throw RecoverySyncError.accountMismatch }
    }
    private func processBatch(_ items: [WhoopRecovery], state: inout RecoverySyncState,
                              access: HealthReadAccess, now: Date) async throws {
        let confirmedSummary = lastSummary
        do {
            for item in items {
                try await process(item, state: &state, access: access, now: now)
                if state.pausedForNativeExport { break }
            }
            try commitProgress(&state)
        } catch {
            if error is CancellationError {
                try commitProgress(&state)
                throw error
            }
            // Saved-but-uncommitted records remain in the durable journal. Publish only confirmed batches.
            lastSummary = confirmedSummary
            throw error
        }
    }
    private func process(_ item: WhoopRecovery, state: inout RecoverySyncState,
                         access: HealthReadAccess, now: Date) async throws {
        try await checkActive(accountKey: item.accountKey)
        guard item.accountKey == state.accountKey else { throw RecoverySyncError.accountMismatch }
        lastSummary.downloaded += 1
        let window = try? item.coverageWindow()
        var samples: [ExistingRecoverySample] = []
        if let window, access.covers(window), item.scoreState == .scored {
            samples = try await health.samples(in: window, identifier: item.identifier)
        }
        var decision = try RecoveryReconciler.plan(recovery: item, local: state.records[item.identifier],
                                                   samples: samples, access: access,
                                                   appBundle: appBundle, officialWhoopBundle: state.officialWhoopBundle)
        if case .write = decision {
            // Recheck external coverage and access immediately before the durable journal + save.
            try await checkActive(accountKey: item.accountKey)
            let freshAccess = try await health.readAccess()
            if case let .nativeExporter(bundle) = freshAccess { state.officialWhoopBundle = bundle }
            let freshSamples = try await health.samples(in: item.coverageWindow(), identifier: item.identifier)
            decision = try RecoveryReconciler.plan(recovery: item, local: state.records[item.identifier],
                                                   samples: freshSamples, access: freshAccess,
                                                   appBundle: appBundle, officialWhoopBundle: state.officialWhoopBundle)
        }
        switch decision {
        case let .write(fingerprint, version):
            try await checkActive(accountKey: item.accountKey)
            let operation = RecoveryPendingOperation(identifier: item.identifier, fingerprint: fingerprint, version: version, sourceQueryRange: item.sleepRange)
            state.pendingOperations[item.identifier] = operation
            try persistence.prepareRecoveryOperation(operation)
            try await checkActive(accountKey: item.accountKey)
            try await health.save(item, fingerprint: fingerprint, version: version)
            let revised = state.records[item.identifier] != nil
            state.records[item.identifier] = RecoverySyncRecord(identifier: item.identifier, fingerprint: fingerprint,
                version: version, sourceUpdatedAt: item.updatedAt, representedDate: item.representedDate)
            state.pendingOperations.removeValue(forKey: item.identifier)
            state.pendingItems.removeValue(forKey: item.cycleID)
            lastSummary.written += 1
            if revised { lastSummary.revised += 1 }
        case let .unchanged(fingerprint, version):
            state.records[item.identifier] = RecoverySyncRecord(identifier: item.identifier, fingerprint: fingerprint,
                version: version, sourceUpdatedAt: item.updatedAt, representedDate: item.representedDate)
            state.pendingOperations.removeValue(forKey: item.identifier)
            state.pendingItems.removeValue(forKey: item.cycleID)
            lastSummary.unchanged += 1
        case .pausedNativeExport:
            state.pausedForNativeExport = true
            lastSummary.status = .pausedNativeExport
        case .skippedExternal, .unscorable:
            state.pendingItems.removeValue(forKey: item.cycleID)
            state.pendingOperations.removeValue(forKey: item.identifier)
            if decision == .skippedExternal { lastSummary.skippedExternal += 1 } else { lastSummary.unscorable += 1 }
        case .pending, .deferredAccess:
            let reason = decision == .pending ? "pending_score" : "access"
            state.pendingItems[item.cycleID] = RecoveryPendingItem(cycleID: item.cycleID,
                firstDetectedAt: state.pendingItems[item.cycleID]?.firstDetectedAt ?? now, reason: reason, range: window)
            if decision == .pending { lastSummary.pending += 1 } else { lastSummary.deferredAccess += 1 }
        case .invalid:
            lastSummary.invalid += 1
            if state.pendingOperations[item.identifier] != nil {
                state.pendingItems[item.cycleID] = RecoveryPendingItem(cycleID: item.cycleID,
                    firstDetectedAt: state.pendingItems[item.cycleID]?.firstDetectedAt ?? now, reason: "contract", range: window)
            } else {
                state.pendingItems.removeValue(forKey: item.cycleID)
            }
        }
    }
}
