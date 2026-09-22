import XCTest
@testable import WHOOPHealthSyncCore

final class PrivateRecoveryAdapterTests: XCTestCase {
    // Synthetic examples; no personal health records or account identifiers.
    private func record(seconds: Any = 0.047123456, state: String = "complete", calibrating: Any = false,
                        nap: Any = false, offset: String = "+02:00") -> [String: Any] {
        ["cycle": ["id": 42, "user_id": 123],
         "recovery": ["user_id": 123, "activity_id": "sleep-id", "hrv_rmssd": seconds, "state": state,
                      "calibrating": calibrating, "updated_at": "2026-08-15T07:10:00Z"],
         "sleeps": [["activity_id": "sleep-id", "is_nap": nap,
                     "during": "[\"2026-08-14T23:00:00Z\",\"2026-08-15T07:00:00Z\")", "timezone_offset": offset]]]
    }
    func testSyntheticRawValuesConvertToUIReferenceWithoutRoundingStoredPrecision() throws {
        for (raw, exactMS, shown) in [(0.047123456, 47.123456, 47.0), (0.058234567, 58.234567, 58.0),
                                    (0.046765432, 46.765432, 47.0)] {
            let item = try WhoopPrivateRecoveryAdapter.decode(record: record(seconds: raw), expectedUserID: "123")
            XCTAssertEqual(try XCTUnwrap(item.milliseconds), exactMS, accuracy: 0.000000001)
            XCTAssertEqual(item.milliseconds?.rounded(), shown)
            XCTAssertEqual(item.representedDate, WhoopDateCodec.date(from: "2026-08-15T07:00:00Z"))
            XCTAssertEqual(item.scoreState, .scored); XCTAssertNoThrow(try item.fingerprint())
            XCTAssertEqual(TimeZone(identifier: item.sourceTimeZoneID)?.secondsFromGMT(), 7200)
        }
    }
    func testMonthBoundaryQueryRecoveryKeepsJanuarySleepEnd() throws {
        var input = record(seconds: 0.042345678)
        var recovery = input["recovery"] as! [String: Any]
        recovery["updated_at"] = "2026-01-01T08:10:00Z"
        input["recovery"] = recovery
        input["sleeps"] = [["activity_id": "sleep-id", "is_nap": false,
            "during": "[\"2025-12-31T23:00:00Z\",\"2026-01-01T08:00:00Z\")", "timezone_offset": "+02:00"]]
        let item = try WhoopPrivateRecoveryAdapter.decode(record: input, expectedUserID: "123")
        let requestedMonthEnd = try XCTUnwrap(WhoopDateCodec.date(from: "2026-01-01T00:00:00Z"))
        XCTAssertGreaterThan(item.representedDate, requestedMonthEnd)
        XCTAssertEqual(item.representedDate, WhoopDateCodec.date(from: "2026-01-01T08:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(item.milliseconds), 42.345678, accuracy: 0.000000001)
        XCTAssertNoThrow(try item.fingerprint())
    }

    func testBooleanAndNonFiniteHRVAreRejectedAtJSONBoundary() throws {
        let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: record(seconds: true))) as! [String: Any]
        XCTAssertThrowsError(try WhoopPrivateRecoveryAdapter.decode(record: json, expectedUserID: "123"))
        for value in [Double.infinity, Double.nan, 0, -0.01, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try WhoopPrivateRecoveryAdapter.decode(record: record(seconds: value), expectedUserID: "123"))
        }
    }
    func testUnknownPrivateStateIsNotTreatedAsAnOfficialStateOrCompletion() {
        for state in ["SCORED", "PENDING_SCORE", "UNSCORABLE", "pending", "unknown"] {
            XCTAssertThrowsError(try WhoopPrivateRecoveryAdapter.decode(record: record(state: state), expectedUserID: "123")) {
                XCTAssertEqual($0 as? RecoverySyncError, .providerContractUnverified)
            }
        }
    }
    func testAccountMismatchAndAmbiguousAssociationRejectBeforeCreatingRecovery() {
        XCTAssertThrowsError(try WhoopPrivateRecoveryAdapter.decode(record: record(), expectedUserID: "456"))
        var duplicate = record(); duplicate["sleeps"] = (duplicate["sleeps"] as! [[String: Any]]) + (duplicate["sleeps"] as! [[String: Any]])
        XCTAssertThrowsError(try WhoopPrivateRecoveryAdapter.decode(record: duplicate, expectedUserID: "123"))
        XCTAssertThrowsError(try WhoopPrivateRecoveryAdapter.decode(record: record(nap: true), expectedUserID: "123"))
    }
    func testCalibrationRetainedAndFingerprintRejectsWritingIt() throws {
        let item = try WhoopPrivateRecoveryAdapter.decode(record: record(calibrating: 1, nap: 0), expectedUserID: "123")
        XCTAssertTrue(item.userCalibrating); XCTAssertThrowsError(try item.fingerprint())
        XCTAssertThrowsError(try WhoopPrivateRecoveryAdapter.decode(record: record(calibrating: 2), expectedUserID: "123"))
    }
    func testMatchedIANAActivityZonePreservesDSTAndConflictingZonesUseSleepOffset() throws {
        var payload = record()
        payload["v2_activities"] = [["id": "sleep-id", "timezone": "Europe/Madrid"], ["id": "different-sleep", "timezone": "America/New_York"]]
        let item = try WhoopPrivateRecoveryAdapter.decode(record: payload, expectedUserID: "123")
        XCTAssertEqual(item.sourceTimeZoneID, "Europe/Madrid")
        let zone = try XCTUnwrap(TimeZone(identifier: item.sourceTimeZoneID))
        XCTAssertEqual(zone.secondsFromGMT(for: try XCTUnwrap(WhoopDateCodec.date(from: "2026-01-01T00:00:00Z"))), 3600)
        XCTAssertEqual(zone.secondsFromGMT(for: item.representedDate), 7200)
        payload["v2_activities"] = [["id": "sleep-id", "timezone": "Europe/Madrid"], ["source_id": "sleep-id", "timezone": "Europe/London"]]
        let traveled = try WhoopPrivateRecoveryAdapter.decode(record: payload, expectedUserID: "123")
        XCTAssertEqual(TimeZone(identifier: traveled.sourceTimeZoneID)?.secondsFromGMT(), 2 * 3600)
        payload["sleeps"] = [["activity_id": "sleep-id", "is_nap": false,
            "during": "[\"2026-08-14T23:00:00Z\",\"2026-08-15T07:00:00Z\")", "timezone_offset": "not-a-zone"]]
        XCTAssertThrowsError(try WhoopPrivateRecoveryAdapter.decode(record: payload, expectedUserID: "123")) {
            XCTAssertEqual($0 as? RecoverySyncError, .invalidTemporalAssociation)
        }
    }
    func testUnknownOffsetAndBooleanIDsCannotBeValidated() {
        XCTAssertThrowsError(try WhoopPrivateRecoveryAdapter.decode(record: record(offset: "+99:99"), expectedUserID: "123"))
        var bad = record(); bad["cycle"] = ["id": true, "user_id": 123]
        XCTAssertThrowsError(try WhoopPrivateRecoveryAdapter.decode(record: bad, expectedUserID: "123"))
    }
}
