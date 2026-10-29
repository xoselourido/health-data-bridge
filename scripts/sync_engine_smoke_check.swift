import Foundation
import HealthKit
import WHOOPHealthSyncCore

@main
struct SyncEngineSmokeCheck {
    @MainActor
    static func main() async throws {
        try await testIdempotentManualSync()
        try await testLateHeartRateBackfillsWithoutDuplicatingAppleWatchData()
        try await testInterruptedHeartRateRecheckDoesNotRewindCheckpoint()
        try await testHeartRateFailureKeepsSleepCheckpointOnly()
        try await testPartialErrorsAreSanitizedBeforeSummaryAndLogs()
        try await testHeartRateFallbackToMinuteResolution()
        try await testOutOfWindowWhoopDataIsDiscarded()
        try await testConcurrentSyncIsRejected()
        try await testAuthenticationFailureStopsSyncAndMarksRunFailed()
        try await testSleepSaveFailureAfterDeleteDoesNotAdvanceCheckpointAndRetries()
        try await testStrictInitialReadPreflightStopsBeforeWriting()
        try await testInitialReadPreflightUsesWideVisibilityWindowWithoutExpandingWrites()
        try await testOngoingReadVisibilityGuardStopsBeforeWritingWhenHealthKitReadsDisappear()
        try await testHistoricalAccessBoundariesAndExpansion()
        try await testCancelledSleepDoesNotAdvanceOrContinueHeartRate()
        try await testRecoveryCapabilityGatesPreserveExistingFlows()
        try await testLegacyAccountBindingAndChangedAccountStopBeforeQueries()
        try await testExplicitHistoryKeepsLiveCheckpointsAndIsIdempotent()
        try await testCommonHistoryResumesConfirmedChunks()
        try await testHistoryScopeExpansionIsExplicitAndRetainsRecoveryWork()
        try await testHistoryRecoveryFailureResumesWithoutReplayingWindows()
        print("SyncEngine smoke check passed (including late heart-rate backfill, explicit history, durable resume and live-checkpoint continuity)")
    }

    @MainActor
    private static func testIdempotentManualSync() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineSmoke-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let sleep = try makeSleepSession(id: "sleep-engine", start: now.addingTimeInterval(-7_200))
        let heartRatePoints = [
            HeartRatePoint(timestamp: now.addingTimeInterval(-60), bpm: 60, sourceStepSeconds: 6),
            HeartRatePoint(timestamp: now.addingTimeInterval(-54), bpm: 61, sourceStepSeconds: 6)
        ]
        let health = FakeHealthData(
            externalSleep: [
                ExistingSleepSample(
                    id: "apple-sleep",
                    range: sleep.stages[0].range,
                    value: .asleepCore,
                    isOwnedByApp: false,
                    whoopSleepID: nil,
                    syncIdentifier: nil
                )
            ],
            externalHeartRate: [
                ExistingHeartRateSample(
                    id: "apple-hr",
                    range: TimeRange(start: heartRatePoints[0].timestamp, end: heartRatePoints[0].timestamp.addingTimeInterval(6)),
                    bpm: 60,
                    isOwnedByApp: false,
                    syncIdentifier: nil
                )
            ]
        )
        let api = FakeWhoopAPI(sleeps: [sleep], heartRatePoints: heartRatePoints)
        let repository = SyncRepository(fileURL: fileURL)
        let engine = SyncEngine(api: api, healthKit: health, repository: repository, heartRateStepSeconds: 6)

        let first = try await engine.synchronize()
        expect(first.sleepsDownloaded == 1, "First sync should download one sleep.")
        expect(first.stagesWritten == 1, "First sync should write only the WHOOP sleep gap.")
        expect(first.heartRateDownloaded == 2, "First sync should download two HR points.")
        expect(first.heartRateWritten == 1, "First sync should write only uncovered HR bucket.")
        expect(first.errors.isEmpty, "First sync should not report errors.")

        let afterFirst = try repository.checkpoints()
        expect(afterFirst.lastSleepQueryEnd != nil, "First sync should advance sleep checkpoint.")
        expect(afterFirst.lastHeartRateEnd != nil, "First sync should advance HR checkpoint.")

        let second = try await engine.synchronize()
        expect(second.stagesWritten == 0, "Second sync should not rewrite app-owned sleep fragments.")
        expect(second.heartRateWritten == 0, "Second sync should not rewrite app-owned HR points.")
        expect(second.errors.isEmpty, "Second sync should not report errors.")
        let diagnostics = repository.diagnostics()
        expect(diagnostics.recentEvents.contains { $0.category == "sleep.write" }, "Sync should persist sleep write events.")
        expect(diagnostics.recentEvents.contains { $0.category == "hr.write" }, "Sync should persist HR write events.")
        expect(diagnostics.recentEvents.allSatisfy { $0.runID != nil }, "Sync events should be associated with a run ID.")
    }

    @MainActor
    private static func testLateHeartRateBackfillsWithoutDuplicatingAppleWatchData() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("late-heart-rate-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let missing = HeartRatePoint(timestamp: now.addingTimeInterval(-7_200), bpm: 64, sourceStepSeconds: 6)
        let covered = HeartRatePoint(timestamp: now.addingTimeInterval(-7_100), bpm: 66, sourceStepSeconds: 6)
        let external = ExistingHeartRateSample(id: "apple-watch", range: TimeRange(start: covered.timestamp, end: covered.timestamp.addingTimeInterval(6)),
            bpm: 65, isOwnedByApp: false, syncIdentifier: nil)
        let health = FakeHealthData(externalSleep: [], externalHeartRate: [external])
        let api = FakeWhoopAPI(sleeps: [], heartRatePoints: [])
        let repo = SyncRepository(fileURL: url)
        let engine = SyncEngine(api: api, healthKit: health, repository: repo)

        let beforeUpload = try await engine.synchronize()
        expect(beforeUpload.heartRateDownloaded == 0, "An early cloud response can contain no heart-rate points.")
        api.heartRatePoints = [missing, covered]
        let afterUpload = try await engine.synchronize()
        expect(afterUpload.errors.isEmpty && afterUpload.heartRateDownloaded == 2, "A later run must fetch points older than the prior checkpoint.")
        expect(afterUpload.heartRateWritten == 1 && afterUpload.heartRateSkipped == 1, "Backfill must write only the missing WHOOP point.")
        expect(afterUpload.heartRateRemoved == 0, "Backfill must preserve the Apple Watch sample.")
        let repeated = try await engine.synchronize()
        expect(repeated.errors.isEmpty && repeated.heartRateWritten == 0, "Rechecking the same recent window must be idempotent.")
        expect(health.savedHeartRatePointCount == 1, "Three syncs must create only one missing heart-rate record.")
    }

    @MainActor
    private static func testInterruptedHeartRateRecheckDoesNotRewindCheckpoint() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("revision-checkpoint-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let checkpoint = Date().addingTimeInterval(-60)
        let repo = SyncRepository(fileURL: url)
        try repo.bindAccountManually(WhoopRecovery.pseudonymousAccountKey(userID: "fake-user"))
        try repo.setHeartRateCheckpoint(checkpoint, resolution: 60)
        let api = FakeWhoopAPI(sleeps: [], heartRatePoints: [])
        api.heartRateErrorAfterRequestCount = 1
        let engine = SyncEngine(api: api, healthKit: FakeHealthData(externalSleep: [], externalHeartRate: []), repository: repo)

        let summary = try await engine.synchronize()
        expect(!summary.errors.isEmpty, "The second revision chunk should fail in this fixture.")
        let after = try repo.checkpoints()
        expect(after.lastHeartRateEnd == checkpoint, "A completed retrospective chunk must not rewind previously confirmed live progress.")
        expect(after.lastHeartRateResolution == 60, "Historical rechecks must retain the effective resolution at the live checkpoint.")
    }

    @MainActor
    private static func testHeartRateFailureKeepsSleepCheckpointOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineFailure-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let sleep = try makeSleepSession(id: "sleep-partial", start: now.addingTimeInterval(-7_200))
        let heartRatePoints = [
            HeartRatePoint(timestamp: now.addingTimeInterval(-60), bpm: 60, sourceStepSeconds: 6)
        ]
        let health = FakeHealthData(externalSleep: [], externalHeartRate: [])
        health.throwOnHeartRateSave = true

        let repository = SyncRepository(fileURL: fileURL)
        let engine = SyncEngine(
            api: FakeWhoopAPI(sleeps: [sleep], heartRatePoints: heartRatePoints),
            healthKit: health,
            repository: repository,
            heartRateStepSeconds: 6
        )

        let summary = try await engine.synchronize()
        expect(summary.stagesWritten == 2, "Partial sync should still write sleep phases.")
        expect(summary.heartRateWritten == 0, "Failed HR save should not count written HR.")
        expect(!summary.errors.isEmpty, "Failed HR save should report a partial error.")
        expect(summary.sleepResult == .updated && summary.heartRateResult == .failed, "A failed heart-rate phase must not hide confirmed sleep or report an empty successful phase.")

        let checkpoints = try repository.checkpoints()
        expect(checkpoints.lastSleepQueryEnd != nil, "Sleep checkpoint should advance after successful sleep pipeline.")
        expect(checkpoints.lastHeartRateEnd == nil, "HR checkpoint should not advance after failed HR save.")
    }

    @MainActor
    private static func testPartialErrorsAreSanitizedBeforeSummaryAndLogs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineSensitiveError-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let api = FakeWhoopAPI(sleeps: [], heartRatePoints: [])
        api.heartRateError = SensitivePartialSmokeError()
        let repository = SyncRepository(fileURL: fileURL)
        let engine = SyncEngine(
            api: api,
            healthKit: FakeHealthData(externalSleep: [], externalHeartRate: []),
            repository: repository,
            heartRateStepSeconds: 6
        )

        let summary = try await engine.synchronize()
        let summaryText = summary.errors.joined(separator: "\n")
        let eventText = repository.diagnostics().recentEvents.map(\.message).joined(separator: "\n")
        let combinedText = [summaryText, eventText].joined(separator: "\n")

        expect(!summary.errors.isEmpty, "Sensitive partial failure should still surface an error.")
        expect(!combinedText.contains("jose@example.com"), "SyncEngine should redact emails before summary/events.")
        expect(!combinedText.contains("secret-token"), "SyncEngine should redact bearer token material before summary/events.")
        expect(!combinedText.contains("secret-password"), "SyncEngine should redact password material before summary/events.")
        expect(!combinedText.contains("refresh-secret"), "SyncEngine should redact refresh token material before summary/events.")
        expect(!combinedText.contains("header.payload.signature"), "SyncEngine should redact JWT-like values before summary/events.")
        expect(combinedText.contains("[redacted-email]"), "Sanitized summary/events should show email redaction marker.")
        expect(combinedText.contains("Bearer [redacted-token]"), "Sanitized summary/events should show bearer redaction marker.")
        expect(repository.diagnostics().lastRunStatus == "partial", "A non-auth HR failure after sleep pipeline should remain a partial run.")
        expect(repository.diagnostics().lastRunErrorsText.contains("[redacted-email]"), "Partial run diagnostics should preserve sanitized error text after sync.")
        expect(repository.diagnostics().lastRunErrorsText.contains("Bearer [redacted-token]"), "Partial run diagnostics should redact token material in persisted error text.")
    }

    @MainActor
    private static func testHeartRateFallbackToMinuteResolution() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineFallback-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let point = HeartRatePoint(timestamp: now.addingTimeInterval(-120), bpm: 64, sourceStepSeconds: 60)
        let api = FakeWhoopAPI(sleeps: [], heartRatePoints: [point])
        api.unsupportedHeartRateSteps = [6]

        let repository = SyncRepository(fileURL: fileURL)
        let engine = SyncEngine(
            api: api,
            healthKit: FakeHealthData(externalSleep: [], externalHeartRate: []),
            repository: repository,
            heartRateStepSeconds: 6,
            heartRateFallbackStepSeconds: 60
        )

        let summary = try await engine.synchronize()
        expect(api.requestedHeartRateSteps.prefix(2) == [6, 60], "HR sync should retry with 60 seconds when 6 seconds is rejected.")
        expect(summary.effectiveHeartRateResolution == 60, "Summary should expose the fallback HR resolution.")
        expect(summary.heartRateWritten == 1, "Fallback HR sync should still write uncovered samples.")
        let checkpoints = try repository.checkpoints()
        expect(checkpoints.lastHeartRateResolution == 60, "HR checkpoint should persist the effective fallback resolution.")
    }

    @MainActor
    private static func testOutOfWindowWhoopDataIsDiscarded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineWindow-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let validSleep = try makeSleepSession(id: "sleep-inside", start: now.addingTimeInterval(-7_200))
        let futureSleep = try makeSleepSession(id: "sleep-future", start: now.addingTimeInterval(3_600))
        let validPoint = HeartRatePoint(timestamp: now.addingTimeInterval(-120), bpm: 64, sourceStepSeconds: 6)
        let futurePoint = HeartRatePoint(timestamp: now.addingTimeInterval(60), bpm: 65, sourceStepSeconds: 6)

        let api = FakeWhoopAPI(sleeps: [validSleep, futureSleep], heartRatePoints: [validPoint, futurePoint])
        api.filterHeartRateByRequestWindow = false

        let repository = SyncRepository(fileURL: fileURL)
        try repository.bindAccountManually(WhoopRecovery.pseudonymousAccountKey(userID: "fake-user"))
        try repository.setHeartRateCheckpoint(now.addingTimeInterval(-180), resolution: 6)
        let engine = SyncEngine(
            api: api,
            healthKit: FakeHealthData(externalSleep: [], externalHeartRate: []),
            repository: repository,
            heartRateStepSeconds: 6
        )

        let summary = try await engine.synchronize()
        expect(summary.sleepsDownloaded == 2, "Window test should download both sleep activity IDs.")
        expect(summary.sleepsDiscardedOutOfWindow == 1, "Future sleep should be discarded before HealthKit writes.")
        expect(summary.sleepsWritten == 1, "Only in-window sleep should be written.")
        let rawPointCount = 2 * api.requestedHeartRateSteps.count
        expect(summary.heartRateDownloaded == rawPointCount, "Window test should count raw HR points from every revision chunk.")
        expect(summary.heartRateDiscardedOutOfWindow == rawPointCount - 1, "Only one point belongs to a requested chunk; all other returned points must be discarded.")
        expect(summary.heartRateWritten == 1, "Only in-window HR point should be written.")
    }

    @MainActor
    private static func testConcurrentSyncIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineConcurrent-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let api = BlockingWhoopAPI()
        let deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            fatalError("Concurrency handshake test timed out after 30 seconds")
        }
        defer { deadline.cancel(); api.release() }
        let engine = SyncEngine(
            api: api,
            healthKit: FakeHealthData(externalSleep: [], externalHeartRate: []),
            repository: SyncRepository(fileURL: fileURL),
            heartRateStepSeconds: 6
        )

        let first = Task { @MainActor in
            try await engine.synchronize()
        }
        await api.waitUntilFetchCurrentUserStarted()

        do {
            _ = try await engine.synchronize()
            fatalError("Concurrent sync should be rejected.")
        } catch let error as SyncEngineError {
            expect(error == .syncAlreadyRunning, "Concurrent sync should throw syncAlreadyRunning.")
        }

        api.release()
        _ = try await first.value
    }

    @MainActor
    private static func testAuthenticationFailureStopsSyncAndMarksRunFailed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineAuthFailure-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let sleep = try makeSleepSession(id: "sleep-before-auth-failure", start: now.addingTimeInterval(-7_200))
        let api = FakeWhoopAPI(sleeps: [sleep], heartRatePoints: [])
        api.heartRateError = WhoopAPIError.http(status: 401, path: "/metrics-service/v1/metrics/user/fake-user", message: "expired")

        let repository = SyncRepository(fileURL: fileURL)
        let engine = SyncEngine(
            api: api,
            healthKit: FakeHealthData(externalSleep: [], externalHeartRate: []),
            repository: repository,
            heartRateStepSeconds: 6
        )

        do {
            _ = try await engine.synchronize()
            fatalError("Authentication failure should be propagated to the caller.")
        } catch {
            expect(SyncEngine.isAuthenticationFailure(error), "401 API errors should be classified as authentication failures.")
        }

        let checkpoints = try repository.checkpoints()
        expect(checkpoints.lastSleepQueryEnd != nil, "Completed sleep pipeline should keep its checkpoint before a later auth failure.")
        expect(checkpoints.lastHeartRateEnd == nil, "Failed HR auth should not advance the HR checkpoint.")
        expect(repository.diagnostics().lastRunStatus == "failed", "Auth failure should mark the run as failed.")
    }

    @MainActor
    private static func testSleepSaveFailureAfterDeleteDoesNotAdvanceCheckpointAndRetries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineSleepWriteFailure-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let sleep = try makeSleepSession(id: "sleep-retry-after-delete", start: now.addingTimeInterval(-7_200))
        let staleOwnedSleep = ExistingSleepSample(
            id: "stale-owned-sleep",
            range: sleep.stages[0].range,
            value: .asleepCore,
            isOwnedByApp: true,
            whoopSleepID: sleep.whoopSleepID,
            whoopSleepFingerprint: "old-fingerprint",
            syncIdentifier: "old-sync"
        )
        let health = FakeHealthData(externalSleep: [staleOwnedSleep], externalHeartRate: [])
        health.throwOnSleepSave = true
        let repository = SyncRepository(fileURL: fileURL)
        let engine = SyncEngine(
            api: FakeWhoopAPI(sleeps: [sleep], heartRatePoints: []),
            healthKit: health,
            repository: repository,
            heartRateStepSeconds: 6
        )

        let failed = try await engine.synchronize()
        expect(!failed.errors.isEmpty, "Failed sleep save should be reported as a partial sync error.")
        expect(failed.stagesWritten == 0, "Failed sleep save should not count stages as written.")
        let checkpointsAfterFailure = try repository.checkpoints()
        expect(checkpointsAfterFailure.lastSleepQueryEnd == nil, "Sleep checkpoint should not advance after a sleep HealthKit write failure.")
        expect(!health.hasSleepSample(id: staleOwnedSleep.id), "The injected failure happens after deleting stale app-owned sleep samples.")

        health.throwOnSleepSave = false
        let retried = try await engine.synchronize()
        expect(retried.errors.isEmpty, "Retry after transient sleep save failure should succeed.")
        expect(retried.stagesWritten == sleep.stages.count, "Retry should write the full current hypnogram after stale samples were removed.")
        let checkpointsAfterRetry = try repository.checkpoints()
        expect(checkpointsAfterRetry.lastSleepQueryEnd != nil, "Successful retry should advance the sleep checkpoint.")
        expect(health.ownedSleepSampleCount == sleep.stages.count, "Retry should leave only the current app-owned sleep phases.")
    }

    @MainActor
    private static func testStrictInitialReadPreflightStopsBeforeWriting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineReadPreflight-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let sleep = try makeSleepSession(id: "sleep-read-preflight", start: now.addingTimeInterval(-7_200))
        let health = FakeHealthData(externalSleep: [], externalHeartRate: [])
        let repository = SyncRepository(fileURL: fileURL)
        let engine = SyncEngine(
            api: FakeWhoopAPI(sleeps: [sleep], heartRatePoints: [
                HeartRatePoint(timestamp: now.addingTimeInterval(-60), bpm: 62, sourceStepSeconds: 6)
            ]),
            healthKit: health,
            repository: repository,
            heartRateStepSeconds: 6,
            requiresInitialHealthKitReadVisibility: true
        )

        do {
            _ = try await engine.synchronize()
            fatalError("Strict first-sync HealthKit read preflight should stop when no external samples are visible.")
        } catch let error as SyncEngineError {
            expect(
                error == .healthKitReadVisibilityUnverified(["Sleep Analysis", "Heart Rate"]),
                "Strict preflight should report both missing read-visible types."
            )
        }

        let checkpoints = try repository.checkpoints()
        expect(checkpoints.lastSleepQueryEnd == nil, "Read preflight failure should not advance sleep checkpoint.")
        expect(checkpoints.lastHeartRateEnd == nil, "Read preflight failure should not advance HR checkpoint.")
        expect(health.savedSleepFragmentCount == 0, "Read preflight failure should stop before saving sleep.")
        expect(health.savedHeartRatePointCount == 0, "Read preflight failure should stop before saving HR.")
        expect(repository.diagnostics().lastRunStatus == "failed", "Read preflight failure should mark the run failed.")
    }

    @MainActor
    private static func testInitialReadPreflightUsesWideVisibilityWindowWithoutExpandingWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineWideReadPreflight-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let sleep = try makeSleepSession(id: "sleep-wide-read-preflight", start: now.addingTimeInterval(-7_200))
        let heartRatePoint = HeartRatePoint(timestamp: now.addingTimeInterval(-60), bpm: 62, sourceStepSeconds: 6)
        let priorAppleSleep = ExistingSleepSample(
            id: "apple-watch-sleep-two-weeks-ago",
            range: TimeRange(
                start: now.addingTimeInterval(-14 * 24 * 60 * 60),
                end: now.addingTimeInterval(-14 * 24 * 60 * 60 + 3_600)
            ),
            value: .asleepCore,
            isOwnedByApp: false,
            whoopSleepID: nil,
            syncIdentifier: nil
        )
        let priorAppleHeartRate = ExistingHeartRateSample(
            id: "apple-watch-hr-two-weeks-ago",
            range: TimeRange(
                start: now.addingTimeInterval(-14 * 24 * 60 * 60),
                end: now.addingTimeInterval(-14 * 24 * 60 * 60 + 6)
            ),
            bpm: 59,
            isOwnedByApp: false,
            syncIdentifier: nil
        )
        let health = FakeHealthData(externalSleep: [priorAppleSleep], externalHeartRate: [priorAppleHeartRate])
        let engine = SyncEngine(
            api: FakeWhoopAPI(sleeps: [sleep], heartRatePoints: [heartRatePoint]),
            healthKit: health,
            repository: SyncRepository(fileURL: fileURL),
            heartRateStepSeconds: 6,
            requiresInitialHealthKitReadVisibility: true,
            initialReadVisibilityLookbackDays: 30
        )

        let summary = try await engine.synchronize()

        expect(summary.errors.isEmpty, "Wide read preflight should not block when older Apple Watch data proves read visibility.")
        expect(summary.stagesWritten == sleep.stages.count, "Older Apple Watch sleep should not block current WHOOP sleep writes.")
        expect(summary.heartRateWritten == 1, "Older Apple Watch HR should not block current WHOOP HR writes.")
        expect(summary.sleepQueryWindowStart != nil && summary.sleepQueryWindowStart! > now.addingTimeInterval(-8 * 24 * 60 * 60), "Write sleep query window should remain the normal initial lookback, not the 30-day read preflight.")
        expect(summary.heartRateWindowStart != nil && summary.heartRateWindowStart! > now.addingTimeInterval(-8 * 24 * 60 * 60), "Write HR window should remain the normal initial lookback, not the 30-day read preflight.")
        expect(health.sleepQueryWindows.first?.start ?? now < now.addingTimeInterval(-29 * 24 * 60 * 60), "Sleep read preflight should use the wider visibility window.")
        expect(health.heartRateQueryWindows.first?.start ?? now < now.addingTimeInterval(-29 * 24 * 60 * 60), "HR read preflight should use the wider visibility window.")
    }

    @MainActor
    private static func testOngoingReadVisibilityGuardStopsBeforeWritingWhenHealthKitReadsDisappear() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncEngineOngoingReadGuard-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let repository = SyncRepository(fileURL: fileURL)
        try repository.bindAccountManually(WhoopRecovery.pseudonymousAccountKey(userID: "fake-user"))
        let previousCheckpoint = now.addingTimeInterval(-3_600)
        try repository.setSleepCheckpoint(previousCheckpoint)
        try repository.setHeartRateCheckpoint(previousCheckpoint, resolution: 6)
        let api = FakeWhoopAPI(
            sleeps: [try makeSleepSession(id: "sleep-read-guard", start: now.addingTimeInterval(-1_800))],
            heartRatePoints: [HeartRatePoint(timestamp: now.addingTimeInterval(-60), bpm: 62, sourceStepSeconds: 6)]
        )
        let health = FakeHealthData(externalSleep: [], externalHeartRate: [])
        let engine = SyncEngine(
            api: api,
            healthKit: health,
            repository: repository,
            heartRateStepSeconds: 6,
            requiresInitialHealthKitReadVisibility: true
        )

        do {
            _ = try await engine.synchronize()
            fatalError("Ongoing HealthKit read guard should stop when reads unexpectedly return no visible samples.")
        } catch let error as SyncEngineError {
            expect(
                error == .healthKitReadVisibilityUnverified(["Sleep Analysis", "Heart Rate"]),
                "Ongoing read guard should report both invisible HealthKit types."
            )
        }

        let checkpoints = try repository.checkpoints()
        expect(checkpoints.lastSleepQueryEnd == previousCheckpoint, "Ongoing read guard should not advance sleep checkpoint.")
        expect(checkpoints.lastHeartRateEnd == previousCheckpoint, "Ongoing read guard should not advance HR checkpoint.")
        expect(health.savedSleepFragmentCount == 0, "Ongoing read guard should stop before saving sleep.")
        expect(health.savedHeartRatePointCount == 0, "Ongoing read guard should stop before saving HR.")
        expect(api.currentUserRequestCount == 1, "Account identity must be checked before reusing checkpoints, even when the read guard then fails.")
        expect(repository.diagnostics().lastRunStatus == "failed", "Ongoing read guard failure should mark the run failed.")
    }


    @MainActor
    private static func testLegacyAccountBindingAndChangedAccountStopBeforeQueries() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("account-migration-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = SyncRepository(fileURL: url)
        let checkpoint = Date().addingTimeInterval(-3600)
        try repo.setSleepCheckpoint(checkpoint)
        try repo.setHeartRateCheckpoint(checkpoint, resolution: 6)
        let health = FakeHealthData(externalSleep: [], externalHeartRate: [])
        let api = FakeWhoopAPI(sleeps: [], heartRatePoints: [])
        let engine = SyncEngine(api: api, healthKit: health, repository: repo)
        do { _ = try await engine.synchronize(); fatalError("Legacy progress must require explicit binding") }
        catch let error as SyncRepositoryError { guard case .accountBindingRequired = error else { throw error } }
        expect(health.sleepQueryWindows.isEmpty && health.heartRateQueryWindows.isEmpty, "Unbound progress must stop before HealthKit reads or writes.")
        try expect(try repo.checkpoints().lastSleepQueryEnd == checkpoint && repo.checkpoints().lastHeartRateEnd == checkpoint, "Unbound rejection retains both checkpoints.")
        let rejectedSnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let rejected = (rejectedSnapshot["runs"] as! [[String: Any]]).last!
        expect(rejected["sleepWindowStart"] == nil && rejected["heartRateWindowStart"] == nil, "Rejected runs must not invent query windows.")
        try repo.bindAccountManually(WhoopRecovery.pseudonymousAccountKey(userID: "fake-user"))
        api.userID = "different-user"
        do { _ = try await engine.synchronize(); fatalError("Changed account must stop") }
        catch let error as RecoverySyncError { expect(error == .accountMismatch, "Changed account reports mismatch.") }
        expect(health.sleepQueryWindows.isEmpty && health.heartRateQueryWindows.isEmpty, "Changed account must stop before any HealthKit query.")
        try expect(try repo.checkpoints().lastSleepQueryEnd == checkpoint && repo.checkpoints().lastHeartRateEnd == checkpoint, "Changed-account rejection retains old checkpoints.")
    }

    private static func makeSleepSession(id: String, start: Date) throws -> SleepSession {
        try SleepNormalizer.normalize(
            SleepSession(
                whoopSleepID: id,
                sourceUpdatedAt: start.addingTimeInterval(4_000),
                start: start,
                end: start.addingTimeInterval(3_600),
                timezoneOffsetSeconds: nil,
                isNap: false,
                stages: [
                    SleepStageInterval(start: start, end: start.addingTimeInterval(1_800), stage: .core),
                    SleepStageInterval(start: start.addingTimeInterval(1_800), end: start.addingTimeInterval(3_600), stage: .rem)
                ]
            )
        )
    }

    @MainActor
    private static func testRecoveryCapabilityGatesPreserveExistingFlows() async throws {
        for (enabled, supported) in [(false, true), (true, false), (true, true)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-gate-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let repo = SyncRepository(fileURL: url)
            let sleep = try makeSleepSession(id: "gated", start: Date().addingTimeInterval(-7200))
            let health = FakeHealthData(externalSleep: [], externalHeartRate: [])
            let provider = GatedRecoveryProvider(), recoveryHealth = GatedRecoveryHealth(supported: supported)
            var state = try repo.recoveryState(); state.enabled = enabled; state.configured = true
            state.accountKey = WhoopRecovery.pseudonymousAccountKey(userID: "fake-user")
            try repo.commitRecoveryState(state)
            let pipeline = RecoverySyncPipeline(provider: provider, health: recoveryHealth, persistence: repo, appBundle: "test")
            let api = FakeWhoopAPI(sleeps: [sleep], heartRatePoints: [])
            let engine = SyncEngine(api: api, healthKit: health, repository: repo, recoveryPipeline: pipeline)
            let summary = try await engine.synchronize()
            expect(summary.stagesWritten == sleep.stages.count, "Recovery gating must preserve the completed sleep flow.")
            try expect(try repo.checkpoints().lastHeartRateEnd != nil, "Recovery gating must preserve the HR checkpoint.")
            expect(provider.calls == 0 && recoveryHealth.calls == 0, "Unvalidated, disabled or unsupported recovery must make no provider/store calls.")
            if enabled && supported {
                expect(!summary.errors.isEmpty, "Unvalidated active recovery must produce a partial result.")
            } else {
                expect(summary.errors.isEmpty, "Disabled/unsupported recovery must not turn valid legacy flows into failures.")
            }
        }
    }

    @MainActor
    private static func testHistoricalAccessBoundariesAndExpansion() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let sleep = try makeSleepSession(id: "boundary", start: now.addingTimeInterval(-7200))
        let points = [HeartRatePoint(timestamp: now.addingTimeInterval(-60), bpm: 60, sourceStepSeconds: 6),
                      HeartRatePoint(timestamp: now.addingTimeInterval(-48), bpm: 61, sourceStepSeconds: 6)]
        let health = FakeHealthData(externalSleep: [], externalHeartRate: [])
        health.sleepBoundary = sleep.start.addingTimeInterval(1)
        health.heartRateBoundary = points[0].timestamp.addingTimeInterval(1)
        let repository = SyncRepository(fileURL: url)
        let engine = SyncEngine(api: FakeWhoopAPI(sleeps: [sleep], heartRatePoints: points), healthKit: health, repository: repository)
        let limited = try await engine.synchronize()
        expect(limited.stagesWritten == 0, "A night crossing the boundary must be deferred whole.")
        expect(limited.heartRateWritten == 1, "Only fully authorized HR buckets may be written.")
        expect(limited.hasIncompleteResults, "Confirmed HR writes do not certify phases blocked by limited reading.")
        expect(repository.diagnostics().lastRunStatus == "partial", "Limited reading must persist a partial run even without global errors.")
        try expect(try repository.deferredWindow(for: "sleep") != nil, "Deferred sleep must persist.")
        try expect(try repository.deferredWindow(for: "heartRate") != nil, "Deferred HR must persist.")
        health.sleepBoundary = nil; health.heartRateBoundary = nil
        let expanded = try await engine.synchronize()
        expect(expanded.stagesWritten == sleep.stages.count, "Expanded access must revisit the deferred night.")
        expect(expanded.heartRateWritten == 1, "Expanded access must fill only the earlier missing bucket.")
        try expect(try repository.deferredWindow(for: "sleep") == nil, "Resolved sleep deferral must clear.")
        try expect(try repository.deferredWindow(for: "heartRate") == nil, "Resolved HR deferral must clear.")
    }
    @MainActor
    private static func testCancelledSleepDoesNotAdvanceOrContinueHeartRate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let sleep = try makeSleepSession(id: "cancel", start: Date().addingTimeInterval(-7200))
        let health = FakeHealthData(externalSleep: [], externalHeartRate: []); health.cancelSleepSave = true
        let repo = SyncRepository(fileURL: url)
        let engine = SyncEngine(api: FakeWhoopAPI(sleeps: [sleep], heartRatePoints: []), healthKit: health, repository: repo)
        do { _ = try await engine.synchronize(); fatalError("Cancellation must propagate") }
        catch { expect(error is CancellationError, "Cancellation must retain its identity.") }
        try expect(try repo.checkpoints().lastSleepQueryEnd == nil, "Cancelled flow cannot advance checkpoint.")
        expect(health.heartRateQueryWindows.isEmpty, "Global cancellation stops subsequent flows.")
        expect(repo.diagnostics().lastRunStatus == "cancelled", "Cancellation must not appear completed.")
    }

    @MainActor
    private static func testExplicitHistoryKeepsLiveCheckpointsAndIsIdempotent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-engine-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let repo = SyncRepository(fileURL: url)
        try repo.bindAccountManually(WhoopRecovery.pseudonymousAccountKey(userID: "fake-user"))
        try repo.setSleepCheckpoint(now); try repo.setHeartRateCheckpoint(now, resolution: 60)
        let before = try repo.checkpoints()
        let deferred = TimeRange(start: now.addingTimeInterval(-86400), end: now)
        try repo.setDeferredWindow(deferred, for: "sleep"); try repo.setDeferredWindow(deferred, for: "heartRate")
        let start = now.addingTimeInterval(-40 * 86400)
        let window = TimeRange(start: start, end: start.addingTimeInterval(86400))
        let sleep = try makeSleepSession(id: "old-history", start: start.addingTimeInterval(7200))
        let point = HeartRatePoint(timestamp: start.addingTimeInterval(120), bpm: 61, sourceStepSeconds: 6)
        let health = FakeHealthData(externalSleep: [], externalHeartRate: [])
        let engine = SyncEngine(api: FakeWhoopAPI(sleeps: [sleep], heartRatePoints: [point]), healthKit: health, repository: repo)
        let first = try await engine.synchronize(recoveryMode: .recent, historyWindow: window)
        expect(first.stagesWritten == sleep.stages.count && first.heartRateWritten == 1, "Explicit history writes older data for both existing data types.")
        try expect(try repo.checkpoints() == before, "History must not rewind or replace live checkpoints/resolution.")
        try expect(try repo.deferredWindow(for: "sleep") == deferred && repo.deferredWindow(for: "heartRate") == deferred, "History must not clear unrelated live deferred work.")
        let second = try await engine.synchronize(recoveryMode: .recent, historyWindow: window)
        expect(second.stagesWritten == 0 && second.heartRateWritten == 0, "Replaying a history chunk is idempotent.")
        expect(second.sleepResult == .existing && second.heartRateResult == .existing, "A verified replay reports existing data, not merely zero writes.")
        health.sleepBoundary = window.end; health.heartRateBoundary = window.end
        let limited = try await engine.synchronize(recoveryMode: .recent, historyWindow: window)
        expect(!limited.errors.isEmpty && limited.stagesWritten == 0 && limited.heartRateWritten == 0, "Limited historical access must leave the chunk unresolved.")
        try expect(try repo.checkpoints() == before && repo.deferredWindow(for: "sleep") == deferred && repo.deferredWindow(for: "heartRate") == deferred, "Limited history must not expand the daily/automation workload.")
        health.sleepBoundary = window.start.addingTimeInterval(60); health.heartRateBoundary = window.start.addingTimeInterval(60)
        let emptyEngine = SyncEngine(api: FakeWhoopAPI(sleeps: [], heartRatePoints: []), healthKit: health, repository: repo)
        let empty = try await emptyEngine.synchronize(recoveryMode: .recent, historyWindow: window)
        expect(!empty.errors.isEmpty && empty.sleepResult == .pendingAccess && empty.heartRateResult == .pendingAccess,
            "Even an empty provider response cannot confirm a historical window whose read boundary excludes its start.")
        try expect(try repo.checkpoints() == before, "Empty limited history preserves live progress.")
        health.sleepBoundary = nil; health.heartRateBoundary = nil
        let readableEmpty = try await emptyEngine.synchronize(recoveryMode: .recent, historyWindow: window)
        expect(readableEmpty.sleepResult == .noData && readableEmpty.heartRateResult == .noData,
            "An accessible empty provider response is distinct from already-existing samples and pending access.")
    }

    @MainActor
    private static func testCommonHistoryResumesConfirmedChunks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-resume-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 5_000_000)
        let start = now.addingTimeInterval(-15 * 86400)
        var requests: [TimeRange] = []
        var recoveryCalls = 0
        let repo = SyncRepository(fileURL: url)
        let interrupted = HistoryImporter(repository: repo, syncWindow: { window in
            requests.append(window)
            if requests.count == 2 { throw CancellationError() }
            var summary = SyncSummary(); summary.stagesWritten = 1; return summary
        }, syncRecovery: { recoveryCalls += 1; return RecoverySyncSummary() })
        do { _ = try await interrupted.run(start: start, now: now); fatalError("Expected interrupted history") }
        catch is CancellationError {}
        expect(recoveryCalls == 0 && requests[0].end == start.addingTimeInterval(7 * 86400), "History uses bounded, confirmed chunks before recovery import.")
        let reloaded = SyncRepository(fileURL: url)
        try expect(try reloaded.historyWindow()?.start == requests[0].end, "Only confirmed history chunks advance durable progress.")
        let partial = HistoryImporter(repository: reloaded, syncWindow: { _ in
            var summary = SyncSummary(); summary.errors = ["Health access pending"]; return summary
        }, syncRecovery: { recoveryCalls += 1; return RecoverySyncSummary() })
        _ = try await partial.run(start: nil, now: now.addingTimeInterval(86400))
        try expect(try reloaded.historyWindow()?.start == requests[0].end, "Partial/failed chunks remain pending.")
        requests.removeAll()
        let resumed = HistoryImporter(repository: reloaded, syncWindow: { window in
            requests.append(window); var summary = SyncSummary(); summary.heartRateWritten = 2; return summary
        }, syncRecovery: { recoveryCalls += 1; var summary = RecoverySyncSummary(); summary.written = 3; return summary })
        let result = try await resumed.run(start: nil, now: now.addingTimeInterval(86400))
        expect(requests.count == 2 && requests.last?.end == now, "Resume retains the original cutoff, not a moving target.")
        expect(result.heartRateWritten == 4 && result.recovery.written == 3 && recoveryCalls == 1, "One common history result includes all configured data.")
        try expect(try reloaded.historyWindow() == nil, "Confirmed historical traversal finishes its declared period.")
    }

    @MainActor
    private static func testHistoryScopeExpansionIsExplicitAndRetainsRecoveryWork() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-scope-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = SyncRepository(fileURL: url)
        try repo.bindAccountManually("history-account")
        var state = RecoverySyncState()
        state.accountKey = "history-account"; state.enabled = true; state.configured = true
        state.historyStartDate = Date(timeIntervalSince1970: 1_000_000)
        state.lastDiscoveryEnd = Date(timeIntervalSince1970: 2_000_000)
        state.initialEnumerationComplete = true; state.initialImportCutoff = state.lastDiscoveryEnd
        state.historicalPagesConfirmed = 30; state.historicalCursor = "previous-cursor"
        state.userConfirmedFullReadAccess = true
        state.pendingItems["pending"] = RecoveryPendingItem(cycleID: "pending", firstDetectedAt: state.lastDiscoveryEnd!, reason: "access")
        try repo.commitRecoveryState(state)
        let importer = HistoryImporter(repository: repo, syncWindow: { _ in SyncSummary() }, syncRecovery: { RecoverySyncSummary() })
        let cutoff = Date(timeIntervalSince1970: 2_000_000)
        _ = try await importer.run(start: Date(timeIntervalSince1970: 1_500_000), now: cutoff)
        try expect(try repo.recoveryState() == state, "Requesting later history retains already wider HRV progress.")
        let earlier = Date(timeIntervalSince1970: 500_000)
        _ = try await importer.run(start: earlier, now: cutoff)
        let expanded = try repo.recoveryState()
        expect(expanded.historyStartDate == earlier && !expanded.initialEnumerationComplete && expanded.historicalCursor == nil, "Only an explicit earlier history request reopens enumeration.")
        expect(expanded.lastDiscoveryEnd == state.lastDiscoveryEnd && expanded.pendingItems == state.pendingItems && expanded.userConfirmedFullReadAccess, "Scope extension preserves daily progress, pending records and read confirmation.")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else {
            fatalError(message)
        }
    }

    @MainActor
    private static func testHistoryRecoveryFailureResumesWithoutReplayingWindows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-recovery-retry-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = SyncRepository(fileURL: url)
        let cutoff = Date(timeIntervalSince1970: 5_000_000)
        var windows = 0
        let failing = HistoryImporter(repository: repo, syncWindow: { _ in windows += 1; return SyncSummary() }, syncRecovery: {
            throw RecoverySyncError.rateLimited(until: cutoff.addingTimeInterval(60))
        })
        do { _ = try await failing.run(start: cutoff.addingTimeInterval(-86400), now: cutoff); fatalError("Expected HRV retry") }
        catch let error as RecoverySyncError { guard case .rateLimited = error else { throw error } }
        try expect(try repo.historyWindow() == nil && repo.hasPendingHistoryImport, "HRV-stage failure retains the active import after all earlier windows finish.")
        expect(repo.historyPhase == "recovery" && repo.historyCutoff == cutoff, "The pending phase and fixed cutoff are durable.")
        let reloaded = SyncRepository(fileURL: url)
        let resumed = HistoryImporter(repository: reloaded, syncWindow: { _ in windows += 1; return SyncSummary() }, syncRecovery: { RecoverySyncSummary() })
        _ = try await resumed.run(start: nil, now: cutoff.addingTimeInterval(86400))
        expect(windows == 1 && !reloaded.hasPendingHistoryImport, "Resume retries only HRV, not confirmed sleep/heart-rate windows.")
    }
}

private final class FakeWhoopAPI: WhoopAPIProviding {
    private let sleeps: [SleepSession]
    var heartRatePoints: [HeartRatePoint]
    var heartRateErrorAfterRequestCount: Int?
    var unsupportedHeartRateSteps: Set<Int> = []
    var requestedHeartRateSteps: [Int] = []
    var filterHeartRateByRequestWindow = true
    var heartRateError: Error?
    var userID = "fake-user"
    var currentUserRequestCount = 0

    init(sleeps: [SleepSession], heartRatePoints: [HeartRatePoint]) {
        self.sleeps = sleeps
        self.heartRatePoints = heartRatePoints
    }

    func fetchCurrentUser() async throws -> WhoopUser {
        currentUserRequestCount += 1
        return WhoopUser(id: userID)
    }

    func fetchSleepActivities(userID: String, start: Date, end: Date) async throws -> [WhoopSleepActivity] {
        sleeps.map {
            WhoopSleepActivity(activityID: $0.whoopSleepID, sourceUpdatedAt: $0.sourceUpdatedAt, isNap: $0.isNap)
        }
    }

    func fetchSleepSession(activity: WhoopSleepActivity) async throws -> SleepSession {
        guard let sleep = sleeps.first(where: { $0.whoopSleepID == activity.activityID }) else {
            throw SmokeError.missingSleep(activity.activityID)
        }
        return sleep
    }

    func fetchHeartRate(userID: String, start: Date, end: Date, stepSeconds: Int) async throws -> [HeartRatePoint] {
        requestedHeartRateSteps.append(stepSeconds)
        if let limit = heartRateErrorAfterRequestCount, requestedHeartRateSteps.count > limit {
            throw WhoopAPIError.http(status: 503, path: "/synthetic-heart-rate", message: "injected revision failure")
        }
        if let heartRateError {
            throw heartRateError
        }
        if unsupportedHeartRateSteps.contains(stepSeconds) {
            throw WhoopAPIError.http(status: 400, path: "/metrics-service/v1/metrics/user/\(userID)", message: "unsupported step")
        }
        guard filterHeartRateByRequestWindow else {
            return heartRatePoints
        }
        return heartRatePoints.filter { point in
            point.timestamp >= start && point.timestamp < end
        }
    }
}

@MainActor
private final class BlockingWhoopAPI: WhoopAPIProviding {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var shouldRelease = false

    func waitUntilFetchCurrentUserStarted() async {
        if hasStarted {
            return
        }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func release() {
        shouldRelease = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func fetchCurrentUser() async throws -> WhoopUser {
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        if !shouldRelease {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return WhoopUser(id: "blocking-user")
    }

    func fetchSleepActivities(userID: String, start: Date, end: Date) async throws -> [WhoopSleepActivity] {
        []
    }

    func fetchSleepSession(activity: WhoopSleepActivity) async throws -> SleepSession {
        throw SmokeError.missingSleep(activity.activityID)
    }

    func fetchHeartRate(userID: String, start: Date, end: Date, stepSeconds: Int) async throws -> [HeartRatePoint] {
        []
    }
}

private final class FakeHealthData: HealthDataProviding {
    private let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
    private let heartRateUnit = HKUnit.count().unitDivided(by: .minute())

    private var sleepSamples: [ExistingSleepSample]
    private var heartRateSamples: [ExistingHeartRateSample]
    var sleepBoundary: Date?
    var heartRateBoundary: Date?
    var cancelSleepSave = false
    func authorizedBoundary(for type: String) async throws -> Date? { type == "sleep" ? sleepBoundary : heartRateBoundary }
    var throwOnSleepSave = false
    var throwOnHeartRateSave = false
    var savedSleepFragmentCount = 0
    var savedHeartRatePointCount = 0
    var sleepQueryWindows: [TimeRange] = []
    var heartRateQueryWindows: [TimeRange] = []
    var ownedSleepSampleCount: Int {
        sleepSamples.filter(\.isOwnedByApp).count
    }

    init(externalSleep: [ExistingSleepSample], externalHeartRate: [ExistingHeartRateSample]) {
        self.sleepSamples = externalSleep
        self.heartRateSamples = externalHeartRate
    }

    func querySleepSamples(from start: Date, to end: Date) async throws -> [HealthKitSleepSampleRecord] {
        sleepQueryWindows.append(TimeRange(start: start, end: end))
        return sleepSamples
            .filter { $0.range.overlaps(TimeRange(start: start, end: end)) }
            .map { existing in
                HealthKitSleepSampleRecord(
                    sample: HKCategorySample(
                        type: sleepType,
                        value: sleepValue(existing.value),
                        start: existing.range.start,
                        end: existing.range.end
                    ),
                    existing: existing
                )
            }
    }

    func saveSleepFragments(_ fragments: [SleepWriteFragment]) async throws {
        if cancelSleepSave { throw CancellationError() }
        if throwOnSleepSave {
            throw SmokeError.injectedSleepFailure
        }
        savedSleepFragmentCount += fragments.count
        for fragment in fragments {
            sleepSamples.append(
                ExistingSleepSample(
                    id: SyncIdentifiers.sleep(
                        whoopSleepID: fragment.whoopSleepID,
                        stage: fragment.interval.stage,
                        start: fragment.interval.range.start,
                        end: fragment.interval.range.end
                    ),
                    range: fragment.interval.range,
                    value: existingSleepValue(fragment.interval.stage),
                    isOwnedByApp: true,
                    whoopSleepID: fragment.whoopSleepID,
                    whoopSleepFingerprint: fragment.fingerprint,
                    syncIdentifier: fragment.fingerprint
                )
            )
        }
    }

    func deleteSleepSamples(_ records: [HealthKitSleepSampleRecord]) async throws {
        let ids = Set(records.map(\.existing.id))
        sleepSamples.removeAll { ids.contains($0.id) }
    }

    func hasSleepSample(id: String) -> Bool {
        sleepSamples.contains { $0.id == id }
    }

    func queryHeartRateSamples(from start: Date, to end: Date) async throws -> [HealthKitHeartRateSampleRecord] {
        heartRateQueryWindows.append(TimeRange(start: start, end: end))
        return heartRateSamples
            .filter { $0.range.overlaps(TimeRange(start: start, end: end)) }
            .map { existing in
                HealthKitHeartRateSampleRecord(
                    sample: HKQuantitySample(
                        type: heartRateType,
                        quantity: HKQuantity(unit: heartRateUnit, doubleValue: existing.bpm),
                        start: existing.range.start,
                        end: existing.range.end
                    ),
                    existing: existing
                )
            }
    }

    func saveHeartRatePoints(_ points: [HeartRatePoint], stepSeconds: Int) async throws {
        if throwOnHeartRateSave {
            throw SmokeError.injectedHeartRateFailure
        }
        savedHeartRatePointCount += points.count
        for point in points {
            heartRateSamples.append(
                ExistingHeartRateSample(
                    id: SyncIdentifiers.heartRate(timestamp: point.timestamp, stepSeconds: stepSeconds),
                    range: HeartRateCoverageReconciler.bucket(for: point, stepSeconds: stepSeconds, semantics: .bucketStart),
                    bpm: point.bpm,
                    isOwnedByApp: true,
                    syncIdentifier: SyncIdentifiers.heartRate(timestamp: point.timestamp, stepSeconds: stepSeconds)
                )
            )
        }
    }

    func deleteHeartRateSamples(_ records: [HealthKitHeartRateSampleRecord]) async throws {
        let ids = Set(records.map(\.existing.id))
        heartRateSamples.removeAll { ids.contains($0.id) }
    }

    private func sleepValue(_ value: ExistingSleepValue) -> Int {
        switch value {
        case .awake:
            return HKCategoryValueSleepAnalysis.awake.rawValue
        case .asleepCore:
            return HKCategoryValueSleepAnalysis.asleepCore.rawValue
        case .asleepDeep:
            return HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        case .asleepREM:
            return HKCategoryValueSleepAnalysis.asleepREM.rawValue
        case .asleep, .asleepUnspecified:
            return HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
        case .inBed:
            return HKCategoryValueSleepAnalysis.inBed.rawValue
        case let .other(rawValue):
            return rawValue
        }
    }

    private func existingSleepValue(_ stage: SleepStage) -> ExistingSleepValue {
        switch stage {
        case .awake:
            return .awake
        case .core:
            return .asleepCore
        case .deep:
            return .asleepDeep
        case .rem:
            return .asleepREM
        }
    }
}

private enum SmokeError: Error, LocalizedError {
    case missingSleep(String)
    case injectedSleepFailure
    case injectedHeartRateFailure

    var errorDescription: String? {
        switch self {
        case let .missingSleep(id):
            return "Missing fake sleep \(id)."
        case .injectedSleepFailure:
            return "Injected sleep failure."
        case .injectedHeartRateFailure:
            return "Injected heart-rate failure."
        }
    }
}

private struct SensitivePartialSmokeError: LocalizedError {
    var errorDescription: String? {
        "Failure for jose@example.com Authorization: Bearer secret-token password=secret-password refreshToken=refresh-secret jwt=header.payload.signature"
    }
}

@MainActor private final class GatedRecoveryProvider: WhoopRecoveryProviding {
    let contractValidated = false
    var calls = 0
    func historicalPage(accountKey: String, cutoff: Date, cursor: String?) async throws -> RecoveryPage { calls += 1; throw RecoverySyncError.providerContractUnverified }
    func recentRecords(accountKey: String, window: TimeRange) async throws -> [WhoopRecovery] { calls += 1; throw RecoverySyncError.providerContractUnverified }
    func recovery(accountKey: String, cycleID: String) async throws -> WhoopRecovery { calls += 1; throw RecoverySyncError.providerContractUnverified }
}
@MainActor private final class GatedRecoveryHealth: RecoveryHealthProviding {
    let supported: Bool
    var calls = 0
    init(supported: Bool) { self.supported = supported }
    func readAccess() async throws -> HealthReadAccess { calls += 1; return .unknown }
    func samples(in window: TimeRange, identifier: String) async throws -> [ExistingRecoverySample] { calls += 1; return [] }
    func save(_ recovery: WhoopRecovery, fingerprint: String, version: Int) async throws { calls += 1 }
}
