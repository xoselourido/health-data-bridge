import Foundation
import CoreFoundation

/// Reference adapter for WHOOP's documented V2 object, NOT proof that the private session accepts it.
/// No endpoint is attached to this decoder. G2 must supply a validated transport and sleep association.
public enum WhoopRecoveryReferenceAdapter {
    private struct Object: Decodable {
        let cycle_id: Int64
        let sleep_id: String
        let user_id: Int64
        let updated_at: String
        let score_state: RecoveryScoreState
        let score: Score?
        struct Score: Decodable { let user_calibrating: Bool; let hrv_rmssd_milli: Double? }
    }
    public static func decode(_ data: Data, expectedUserID: String, sleep: SleepSession,
                              sourceTimeZoneID: String) throws -> WhoopRecovery {
        let object: Object
        do { object = try JSONDecoder().decode(Object.self, from: data) }
        catch { throw RecoverySyncError.invalidRecord }
        guard String(object.user_id) == expectedUserID else { throw RecoverySyncError.accountMismatch }
        guard !sleep.isNap, object.sleep_id == sleep.whoopSleepID,
              let updated = WhoopDateCodec.date(from: object.updated_at) else {
            throw RecoverySyncError.invalidTemporalAssociation
        }
        let item = WhoopRecovery(accountKey: WhoopRecovery.pseudonymousAccountKey(userID: expectedUserID),
            cycleID: String(object.cycle_id), sleepID: object.sleep_id,
            sleepRange: TimeRange(start: sleep.start, end: sleep.end), sourceTimeZoneID: sourceTimeZoneID,
            milliseconds: object.score?.hrv_rmssd_milli, scoreState: object.score_state, updatedAt: updated,
            userCalibrating: object.score?.user_calibrating ?? false, adapterVersion: "whoop-v2-reference-v1")
        _ = try item.coverageWindow()
        return item
    }
}

/// Private cycles contract observed using the existing session on 2026-09-15.
/// Seconds-to-ms conversion is supported by seven UI/API comparisons. Only the observed
/// complete state is normalized; unknown states fail rather than adopting OAuth V2 semantics.
/// This decoder alone does not validate historical enumeration or activate the live provider.
public enum WhoopPrivateRecoveryAdapter {
    public static func decode(record: [String: Any], expectedUserID: String) throws -> WhoopRecovery {
        guard let cycle = record["cycle"] as? [String: Any],
              let recovery = record["recovery"] as? [String: Any],
              let cycleID = integerID(cycle["id"]),
              let cycleUser = integerID(cycle["user_id"]),
              let recoveryUser = integerID(recovery["user_id"]) else { throw RecoverySyncError.invalidRecord }
        guard cycleUser == expectedUserID, recoveryUser == expectedUserID else { throw RecoverySyncError.accountMismatch }
        guard recovery["state"] as? String == "complete" else { throw RecoverySyncError.providerContractUnverified }
        guard let sleepID = recovery["activity_id"] as? String, !sleepID.isEmpty,
              let sleeps = record["sleeps"] as? [[String: Any]] else { throw RecoverySyncError.invalidTemporalAssociation }
        let linked = sleeps.filter { $0["activity_id"] as? String == sleepID }
        guard linked.count == 1, let nap = flag(linked[0]["is_nap"]), !nap,
              let range = WhoopPayloadAdapters.timeRange(from: linked[0]["during"]),
              let zone = sourceZone(record: record, sleep: linked[0], cycle: cycle, sleepID: sleepID),
              let updated = WhoopDateCodec.date(from: recovery["updated_at"]),
              let calibrating = flag(recovery["calibrating"]) else { throw RecoverySyncError.invalidTemporalAssociation }
        guard let seconds = recovery["hrv_rmssd"] as? NSNumber,
              CFGetTypeID(seconds) != CFBooleanGetTypeID(), seconds.doubleValue.isFinite, seconds.doubleValue > 0 else {
            throw RecoverySyncError.invalidRecord
        }
        let milliseconds = seconds.doubleValue * 1000
        guard milliseconds.isFinite else { throw RecoverySyncError.invalidRecord }
        let item = WhoopRecovery(accountKey: WhoopRecovery.pseudonymousAccountKey(userID: expectedUserID),
            cycleID: cycleID, sleepID: sleepID, sleepRange: range, sourceTimeZoneID: zone.identifier,
            milliseconds: milliseconds, scoreState: .scored, updatedAt: updated,
            userCalibrating: calibrating, adapterVersion: "whoop-private-cycles-seconds-v1")
        _ = try item.coverageWindow()
        return item
    }
    private static func integerID(_ raw: Any?) -> String? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let id = Int64(n.stringValue), id > 0 else { return nil }
        return String(id)
    }
    private static func flag(_ raw: Any?) -> Bool? {
        guard let n = raw as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if n.doubleValue == 0 { return false }; if n.doubleValue == 1 { return true }; return nil
    }
    private static func sourceZone(record: [String: Any], sleep: [String: Any], cycle: [String: Any], sleepID: String) -> TimeZone? {
        let activities = record["v2_activities"] as? [[String: Any]] ?? []
        let linked = activities.filter { activity in
            ["id", "source_id", "activity_v1_id"].contains { activity[$0] as? String == sleepID }
        }
        let zones = Set(linked.compactMap { $0["timezone"] as? String })
        // One IANA zone preserves daylight-saving rules. Travel can attach a second activity
        // in another zone to the same sleep; the sleep's own offset is then the day boundary.
        if zones.count == 1, let name = zones.first, let zone = TimeZone(identifier: name) {
            return zone
        }
        return offsetZone(sleep["timezone_offset"] ?? cycle["timezone_offset"])
    }
    private static func offsetZone(_ raw: Any?) -> TimeZone? {
        guard let s = raw as? String, s.range(of: "^[+-][0-9]{2}:?[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let digits = String(s.dropFirst()).replacingOccurrences(of: ":", with: "")
        guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)), hours <= 14, minutes < 60,
              hours < 14 || minutes == 0 else { return nil }
        return TimeZone(secondsFromGMT: (s.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }
}
