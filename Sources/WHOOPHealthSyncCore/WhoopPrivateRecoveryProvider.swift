import Foundation
import CoreFoundation

/// Uses the observed private cycles route through injected, authenticated transport.
/// Time windows are walked to a user-declared start; that scope is never reported as provider-certified exhaustion.
@MainActor public final class WhoopPrivateRecoveryProvider: WhoopRecoveryProviding {
    public let contractValidated = true
    private let currentUserID: @MainActor () async throws -> String
    private let fetch: @MainActor (String, TimeRange) async throws -> [[String: Any]]
    private let state: @MainActor () throws -> RecoverySyncState
    private let commitState: @MainActor (RecoverySyncState) throws -> Void
    private let pageDuration: TimeInterval = 7 * 86400
    private struct Cursor: Codable {
        var end: Date
        var start: Date
        var cutoff: Date
        var account: String
    }
    public init(currentUserID: @escaping @MainActor () async throws -> String,
                fetch: @escaping @MainActor (String, TimeRange) async throws -> [[String: Any]],
                state: @escaping @MainActor () throws -> RecoverySyncState,
                commitState: @escaping @MainActor (RecoverySyncState) throws -> Void) {
        self.currentUserID = currentUserID; self.fetch = fetch; self.state = state; self.commitState = commitState
    }
    private func user(accountKey: String) async throws -> String {
        try Task.checkCancellation()
        let id = try await currentUserID()
        guard WhoopRecovery.pseudonymousAccountKey(userID: id) == accountKey else { throw RecoverySyncError.accountMismatch }
        return id
    }
    public func historicalPage(accountKey: String, cutoff: Date, cursor: String?) async throws -> RecoveryPage {
        let id = try await user(accountKey: accountKey)
        guard let start = try state().historyStartDate, start < cutoff else { throw RecoverySyncError.unknownHistoryEnd }
        var end = cutoff
        if let cursor {
            guard cursor.utf8.count <= 2048, let data = Data(base64Encoded: cursor),
                  let saved = try? JSONDecoder().decode(Cursor.self, from: data),
                  saved.start == start, saved.cutoff == cutoff, saved.account == accountKey,
                  saved.end > start, saved.end <= cutoff else { throw RecoverySyncError.cursorExpired }
            end = saved.end
        }
        var duration = min(pageDuration, end.timeIntervalSince(start))
        while true {
            try Task.checkCancellation()
            let lower = max(start, end.addingTimeInterval(-duration))
            let raw = try await fetchRecords(id, TimeRange(start: lower, end: end))
            // Without a cursor signal, a full response may be truncated. Reduce the query rather than advancing it.
            if raw.count >= 50 {
                guard duration > 60 else { throw RecoverySyncError.providerContractUnverified }
                duration /= 2; continue
            }
            let decoded = try decode(raw, userID: id)
            let records = decoded.items.filter { $0.representedDate >= start && $0.representedDate <= cutoff }
            let finished = lower == start
            let next = finished ? nil : try JSONEncoder().encode(Cursor(end: lower, start: start, cutoff: cutoff, account: accountKey)).base64EncodedString()
            return RecoveryPage(records: records, nextCursor: next, endOfHistoryVerified: false, declaredScopeComplete: finished, skippedUnverified: decoded.skipped)
        }
    }
    public func recentRecords(accountKey: String, window: TimeRange) async throws -> [WhoopRecovery] {
        let id = try await user(accountKey: accountKey)
        // A returned sleep may end after its listing window. Include the preceding cycle window, then reconcile by real date/ID.
        return try await records(userID: id, window: TimeRange(start: window.start.addingTimeInterval(-pageDuration), end: window.end), depth: 0)
    }
    public func recovery(accountKey: String, cycleID: String) async throws -> WhoopRecovery {
        let id = try await user(accountKey: accountKey)
        let saved = try state()
        let identifier = "whoop-rmssd:\(accountKey):\(cycleID)"
        let journalRange = saved.pendingOperations[identifier]?.sourceQueryRange
        let storedDate = saved.records[identifier]?.representedDate
        guard let range = saved.pendingItems[cycleID]?.range ?? journalRange ?? storedDate.map({ TimeRange(start: $0.addingTimeInterval(-86400), end: $0.addingTimeInterval(86400)) }) else {
            throw RecoverySyncError.invalidTemporalAssociation
        }
        let candidates = try await records(userID: id,
            window: TimeRange(start: range.start.addingTimeInterval(-pageDuration), end: range.end.addingTimeInterval(86400)), depth: 0)
        guard let item = candidates.first(where: { $0.cycleID == cycleID }) else { throw RecoverySyncError.invalidRecord }
        return item
    }
    private final class QueryBudget { var remaining = 128 }
    private func records(userID: String, window: TimeRange, depth: Int, budget: QueryBudget = QueryBudget()) async throws -> [WhoopRecovery] {
        guard budget.remaining > 0 else { throw RecoverySyncError.providerContractUnverified }
        budget.remaining -= 1
        try Task.checkCancellation()
        let raw = try await fetchRecords(userID, window)
        if raw.count >= 50 {
            guard depth < 14, window.end.timeIntervalSince(window.start) > 60 else { throw RecoverySyncError.providerContractUnverified }
            let middle = window.start.addingTimeInterval(window.end.timeIntervalSince(window.start) / 2)
            let left = try await records(userID: userID, window: TimeRange(start: window.start, end: middle), depth: depth + 1, budget: budget)
            let right = try await records(userID: userID, window: TimeRange(start: middle, end: window.end), depth: depth + 1, budget: budget)
            return try unique(left + right)
        }
        return try decode(raw, userID: userID).items
    }
    private func fetchRecords(_ userID: String, _ window: TimeRange) async throws -> [[String: Any]] {
        if let date = try state().providerRetryNotBefore, date > Date() { throw RecoverySyncError.rateLimited(until: date) }
        do { return try await fetch(userID, window) }
        catch let RecoverySyncError.rateLimited(date) {
            var saved = try state(); saved.providerRetryNotBefore = date
            try commitState(saved)
            throw RecoverySyncError.rateLimited(until: date)
        }
    }
    private func decode(_ records: [[String: Any]], userID: String) throws -> (items: [WhoopRecovery], skipped: Int) {
        var result: [WhoopRecovery] = []
        var skipped = 0
        for record in records {
            try Task.checkCancellation()
            // No recovery object means no available recovery to fabricate; the recent window discovers it if it later appears.
            if record["recovery"] == nil || record["recovery"] is NSNull {
                guard let cycle = record["cycle"] as? [String: Any],
                      let id = cycle["user_id"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(), id.stringValue == userID else { throw RecoverySyncError.accountMismatch }
                continue
            }
            do {
                result.append(try WhoopPrivateRecoveryAdapter.decode(record: record, expectedUserID: userID))
            } catch let error as RecoverySyncError {
                switch error {
                case .invalidTemporalAssociation, .invalidRecord, .providerContractUnverified:
                    // One unverifiable night must not stop the week behind it.
                    skipped += 1
                default:
                    throw error
                }
            }
        }
        return (try unique(result), skipped)
    }
    private func unique(_ records: [WhoopRecovery]) throws -> [WhoopRecovery] {
        var selected: [String: WhoopRecovery] = [:]
        for item in records {
            if let previous = selected[item.identifier] {
                if item.updatedAt < previous.updatedAt { continue }
                if item.updatedAt == previous.updatedAt && item != previous { throw RecoverySyncError.invalidRecord }
            }
            selected[item.identifier] = item
        }
        return selected.values.sorted { $0.representedDate > $1.representedDate }
    }
}
