import Foundation
import WHOOPHealthSyncCore

@main
struct CoreChecks {
    static func main() throws {
        try testExternalDetailedSleepBlocksWhoopStages()
        try testGenericSleepDoesNotBlockDetailedWhoopStages()
        try testPartialExternalDetailedCoverageOnlyWritesGaps()
        try testOwnSleepSampleIsDeletedWhenExternalCoverageAppearsLater()
        testHeartRateExternalSampleBlocksWriteAndRemovesOwnOverlap()
        testHeartRateInstantExternalSampleBlocksWrite()
        testHeartRateOwnEquivalentSampleIsIdempotent()
        testHeartRateOwnDifferentResolutionDoesNotBlockWrite()
        testIncrementalPlannerBacksUpOneHeartRateBucket()
        testIncrementalPlannerUsesStoredHeartRateResolutionOverlap()
        testIncrementalPlannerRevisitsLateArrivingHeartRate()
        testHeartRateChunksCoverWindowWithoutOverlap()
        testSleepQueryWindowIncludesRevisionLookback()
        try testWhoopUserAndCyclePayloadParsing()
        try testWhoopSleepEventsPayloadParsing()
        try testWhoopHeartRatePayloadParsing()
        try testDeterministicSyncIdentifiers()
        try testMigrationSleepWritesOnlyGapsThenBecomesIdempotent()
        testMigrationHeartRateWritesOnlyUncoveredBucketsThenBecomesIdempotent()
        try testWhoopSleepRevisionDeletesOnlyOwnSamplesAndRewritesGaps()
        try testWhoopSleepRevisionUsesHealthKitFingerprintWhenRepositoryIsMissing()
        try testWhoopSleepFallbackIDMigrationUsesFingerprint()
        try testUnrelatedOwnSleepIsNotDeletedByCrossIDRevision()
        testSyncSummaryMergeCombinesCountersAndErrors()
        testSyncSummaryMergeCombinesWindows()
        print("WHOOPHealthSyncCoreChecks passed")
    }

    static func testExternalDetailedSleepBlocksWhoopStages() throws {
        let session = try normalizedSession(stages: [
            stage(0, 60, .core),
            stage(60, 120, .rem)
        ])
        let existing = [
            ExistingSleepSample(
                id: "apple-1",
                range: range(0, 120),
                value: .asleepCore,
                isOwnedByApp: false,
                whoopSleepID: nil,
                syncIdentifier: nil
            )
        ]

        let plan = SleepCoverageReconciler.plan(
            session: session,
            existingSamples: existing,
            fingerprintChanged: false
        )

        expect(plan.fragmentsToWrite.count == 0, "External detailed sleep should block WHOOP fragments.")
        expect(plan.skippedDetailedFragments == 2, "Both WHOOP phases should be counted as covered.")
    }

    static func testGenericSleepDoesNotBlockDetailedWhoopStages() throws {
        let session = try normalizedSession(stages: [
            stage(0, 60, .core),
            stage(60, 120, .deep)
        ])
        let existing = [
            ExistingSleepSample(
                id: "generic",
                range: range(0, 120),
                value: .inBed,
                isOwnedByApp: false,
                whoopSleepID: nil,
                syncIdentifier: nil
            )
        ]

        let plan = SleepCoverageReconciler.plan(
            session: session,
            existingSamples: existing,
            fingerprintChanged: false
        )

        expect(plan.fragmentsToWrite.map(\.interval.range) == [range(0, 60), range(60, 120)], "Generic sleep must not block detailed phases.")
    }

    static func testPartialExternalDetailedCoverageOnlyWritesGaps() throws {
        let session = try normalizedSession(stages: [
            stage(0, 100, .core)
        ])
        let existing = [
            ExistingSleepSample(
                id: "apple-middle",
                range: range(40, 70),
                value: .asleepREM,
                isOwnedByApp: false,
                whoopSleepID: nil,
                syncIdentifier: nil
            )
        ]

        let plan = SleepCoverageReconciler.plan(
            session: session,
            existingSamples: existing,
            fingerprintChanged: false
        )

        expect(plan.fragmentsToWrite.map(\.interval.range) == [range(0, 40), range(70, 100)], "Partial coverage should only leave gaps.")
    }

    static func testOwnSleepSampleIsDeletedWhenExternalCoverageAppearsLater() throws {
        let session = try normalizedSession(stages: [
            stage(0, 60, .core)
        ])
        let existing = [
            ExistingSleepSample(
                id: "own",
                range: range(0, 60),
                value: .asleepCore,
                isOwnedByApp: true,
                whoopSleepID: "sleep-1",
                syncIdentifier: "own-sync"
            ),
            ExistingSleepSample(
                id: "apple",
                range: range(0, 60),
                value: .asleepDeep,
                isOwnedByApp: false,
                whoopSleepID: nil,
                syncIdentifier: nil
            )
        ]

        let plan = SleepCoverageReconciler.plan(
            session: session,
            existingSamples: existing,
            fingerprintChanged: false
        )

        expect(plan.ownSamplesToDelete.map(\.id) == ["own"], "Own sleep sample should be removed when Apple coverage appears.")
        expect(plan.fragmentsToWrite.isEmpty, "External detailed coverage should prevent rewriting.")
    }

    static func testHeartRateExternalSampleBlocksWriteAndRemovesOwnOverlap() {
        let point = HeartRatePoint(timestamp: date(0), bpm: 62, sourceStepSeconds: 6)
        let existing = [
            ExistingHeartRateSample(id: "own", range: range(0, 6), bpm: 62, isOwnedByApp: true, syncIdentifier: "own"),
            ExistingHeartRateSample(id: "apple", range: range(0, 6), bpm: 63, isOwnedByApp: false, syncIdentifier: nil)
        ]

        let plan = HeartRateCoverageReconciler.plan(
            points: [point],
            existingSamples: existing,
            stepSeconds: 6
        )

        expect(plan.pointsToWrite.isEmpty, "External HR should block WHOOP HR.")
        expect(plan.ownSamplesToDelete.map(\.id) == ["own"], "Own overlapping HR should be removed.")
        expect(plan.externalDuplicateCount == 1, "External duplicate should be counted.")
    }

    static func testHeartRateInstantExternalSampleBlocksWrite() {
        let points = [
            HeartRatePoint(timestamp: date(0), bpm: 62, sourceStepSeconds: 6),
            HeartRatePoint(timestamp: date(6), bpm: 63, sourceStepSeconds: 6)
        ]
        let existing = [
            ExistingHeartRateSample(id: "apple-instant-0", range: range(0, 0), bpm: 62, isOwnedByApp: false, syncIdentifier: nil),
            ExistingHeartRateSample(id: "apple-instant-6", range: range(6, 6), bpm: 63, isOwnedByApp: false, syncIdentifier: nil)
        ]

        let plan = HeartRateCoverageReconciler.plan(
            points: points,
            existingSamples: existing,
            stepSeconds: 6
        )

        expect(plan.pointsToWrite.isEmpty, "Instant external HR samples inside WHOOP buckets should block duplicate writes.")
        expect(plan.skippedPointCount == 2, "Instant external HR samples should count as skipped duplicates.")
        expect(plan.externalDuplicateCount == 2, "Instant external HR samples should count as external duplicates.")
    }

    static func testHeartRateOwnEquivalentSampleIsIdempotent() {
        let point = HeartRatePoint(timestamp: date(0), bpm: 62, sourceStepSeconds: 6)
        let existing = [
            ExistingHeartRateSample(id: "own", range: range(0, 6), bpm: 62.2, isOwnedByApp: true, syncIdentifier: "own")
        ]

        let plan = HeartRateCoverageReconciler.plan(
            points: [point],
            existingSamples: existing,
            stepSeconds: 6
        )

        expect(plan.pointsToWrite.isEmpty, "Equivalent own HR should not be duplicated.")
        expect(plan.ownSamplesToDelete.isEmpty, "Equivalent own HR should be preserved.")
        expect(plan.skippedPointCount == 1, "Equivalent own HR should count as skipped.")
    }

    static func testHeartRateOwnDifferentResolutionDoesNotBlockWrite() {
        let oneMinutePoint = HeartRatePoint(timestamp: date(0), bpm: 62, sourceStepSeconds: 60)
        let sixSecondSamples = [
            ExistingHeartRateSample(id: "own-0", range: range(0, 6), bpm: 62, isOwnedByApp: true, syncIdentifier: "heart-rate:0:6"),
            ExistingHeartRateSample(id: "own-6", range: range(6, 12), bpm: 62, isOwnedByApp: true, syncIdentifier: "heart-rate:6000:6")
        ]

        let downgradePlan = HeartRateCoverageReconciler.plan(
            points: [oneMinutePoint],
            existingSamples: sixSecondSamples,
            stepSeconds: 60
        )
        expect(downgradePlan.pointsToWrite == [oneMinutePoint], "Partial 6s own coverage should not block a 60s replacement bucket.")
        expect(downgradePlan.ownSamplesToDelete.map(\.id).sorted() == ["own-0", "own-6"], "Stale 6s own samples should be removed when writing a 60s bucket.")
        expect(downgradePlan.replacedOwnPointCount == 1, "Different-resolution own HR should count as replaced.")

        let sixSecondPoints = [
            HeartRatePoint(timestamp: date(0), bpm: 62, sourceStepSeconds: 6),
            HeartRatePoint(timestamp: date(6), bpm: 62, sourceStepSeconds: 6)
        ]
        let oneMinuteSample = ExistingHeartRateSample(id: "own-60", range: range(0, 60), bpm: 62, isOwnedByApp: true, syncIdentifier: "heart-rate:0:60")
        let upgradePlan = HeartRateCoverageReconciler.plan(
            points: sixSecondPoints,
            existingSamples: [oneMinuteSample],
            stepSeconds: 6
        )
        expect(upgradePlan.pointsToWrite == sixSecondPoints, "Wide 60s own coverage should not block finer 6s points.")
        expect(upgradePlan.ownSamplesToDelete.map(\.id) == ["own-60"], "Stale wide own sample should be removed once when upgrading to finer resolution.")
    }

    static func testIncrementalPlannerBacksUpOneHeartRateBucket() {
        let now = date(1_000)
        let checkpoints = SyncCheckpointState(lastHeartRateEnd: date(500), lastSleepQueryEnd: date(400))

        let plan = SyncWindowPlanner.makePlan(
            now: now,
            checkpoints: checkpoints,
            heartRateStepSeconds: 6,
            heartRateRevisionLookbackDays: 0
        )

        expect(plan.heartRateWindow == range(494, 1_000), "With revision lookback disabled, HR should back up one bucket from the last confirmed checkpoint.")
        expect(plan.sleepDiscoveryWindow == range(400, 1_000), "Sleep should continue from its own checkpoint.")
        expect(plan.isFirstHeartRateSync == false, "HR should not be marked first sync.")
        expect(plan.isFirstSleepSync == false, "Sleep should not be marked first sync.")
    }

    static func testIncrementalPlannerUsesStoredHeartRateResolutionOverlap() {
        let now = date(1_000)
        let checkpoints = SyncCheckpointState(
            lastHeartRateEnd: date(500),
            lastSleepQueryEnd: date(400),
            lastHeartRateResolution: 60
        )

        let plan = SyncWindowPlanner.makePlan(
            now: now,
            checkpoints: checkpoints,
            heartRateStepSeconds: 6,
            heartRateRevisionLookbackDays: 0
        )

        expect(plan.heartRateWindow == range(440, 1_000), "HR should back up by the stored effective resolution when it is wider than the preferred step.")
    }

    static func testIncrementalPlannerRevisitsLateArrivingHeartRate() {
        let now = date(1_000_000)
        let plan = SyncWindowPlanner.makePlan(
            now: now,
            checkpoints: SyncCheckpointState(lastHeartRateEnd: date(999_940), lastSleepQueryEnd: date(999_940))
        )
        let latePoint = HeartRatePoint(timestamp: date(980_000), bpm: 64, sourceStepSeconds: 6)
        expect(plan.heartRateWindow.start <= latePoint.timestamp, "The next sync must revisit recent HR that WHOOP uploaded after the previous checkpoint.")
        expect(plan.heartRateWindow == range(913_600, 1_000_000), "Incremental HR should recheck a bounded 24-hour window.")
    }

    static func testHeartRateChunksCoverWindowWithoutOverlap() {
        let chunks = SyncWindowPlanner.heartRateChunks(
            window: range(0, 21),
            maxChunkSeconds: 6
        )

        expect(chunks == [range(0, 6), range(6, 12), range(12, 18), range(18, 21)], "HR chunks should cover the full window without overlap.")
        expect(SyncWindowPlanner.heartRateChunks(window: range(10, 10), maxChunkSeconds: 6).isEmpty, "Empty HR windows should produce no chunks.")
        expect(SyncWindowPlanner.heartRateChunks(window: range(0, 10), maxChunkSeconds: 0).isEmpty, "Invalid chunk sizes should produce no chunks.")
    }

    static func testSleepQueryWindowIncludesRevisionLookback() {
        let now = date(10_000)
        let plan = SyncWindowPlanner.makePlan(
            now: now,
            checkpoints: SyncCheckpointState(lastHeartRateEnd: date(9_000), lastSleepQueryEnd: date(9_500)),
            firstSyncLookbackDays: 7,
            sleepRevisionLookbackDays: 1,
            heartRateStepSeconds: 6
        )

        expect(plan.sleepDiscoveryWindow == range(9_500, 10_000), "Sleep discovery should start from its own checkpoint.")
        expect(plan.sleepRevisionLookbackWindow == range(10_000 - 86_400, 10_000), "Sleep revision lookback should use the configured lookback.")
        expect(SyncWindowPlanner.sleepQueryWindow(for: plan) == range(10_000 - 86_400, 10_000), "Sleep query should include revision lookback when it is earlier than the checkpoint.")
    }

    static func testSyncSummaryMergeCombinesWindows() {
        var summary = SyncSummary()
        var other = SyncSummary()
        other.heartRateWindowStart = date(0)
        other.heartRateWindowEnd = date(10)
        other.sleepQueryWindowStart = date(20)
        other.sleepQueryWindowEnd = date(30)

        summary.merge(other)

        expect(summary.heartRateWindowStart == date(0), "Summary merge should carry HR window start.")
        expect(summary.heartRateWindowEnd == date(10), "Summary merge should carry HR window end.")
        expect(summary.sleepQueryWindowStart == date(20), "Summary merge should carry sleep query window start.")
        expect(summary.sleepQueryWindowEnd == date(30), "Summary merge should carry sleep query window end.")
    }

    static func testWhoopUserAndCyclePayloadParsing() throws {
        let userPayload = try json(
            """
            {
              "user": {
                "id": 12345
              }
            }
            """
        )
        let userID = try WhoopPayloadAdapters.userID(from: userPayload)
        expect(userID == "12345", "User ID should parse from auth-service payload.")

        let cyclesPayload = try json(
            """
            {
              "records": [
                {
                  "cycle": {"id": "cycle-1"},
                  "sleeps": [
                    {
                      "activity_id": "sleep-1",
                      "updated_at": "2026-07-12T08:00:00.000Z",
                      "is_nap": false
                    },
                    {
                      "activity_id": "sleep-1",
                      "updated_at": "2026-07-12T09:00:00.000Z",
                      "is_nap": false
                    },
                    {
                      "activityId": "nap-1",
                      "updatedAt": "2026-07-12T15:00:00.000Z",
                      "sleep_type": "nap"
                    }
                  ]
                }
              ]
            }
            """
        )
        let activities = WhoopPayloadAdapters.sleepActivities(fromCyclesJSON: cyclesPayload)
        expect(activities.map(\.activityID) == ["nap-1", "sleep-1"], "Cycle payload should deduplicate sleep activity IDs.")
        expect(activities.first { $0.activityID == "sleep-1" }?.sourceUpdatedAt == iso("2026-07-12T09:00:00.000Z"), "Newest duplicate activity should win.")
        expect(activities.first { $0.activityID == "nap-1" }?.isNap == true, "Nap marker should parse from sleep_type.")

        let nestedCyclesPayload = try json(
            """
            {
              "data": {
                "payload": {
                  "records": [
                    {
                      "sleeps": [
                        {
                          "id": "sleep-nested",
                          "modifiedAt": "1783814424000",
                          "isNap": "true"
                        }
                      ]
                    }
                  ]
                }
              }
            }
            """
        )
        let nestedActivities = WhoopPayloadAdapters.sleepActivities(fromCyclesJSON: nestedCyclesPayload)
        expect(nestedActivities.map(\.activityID) == ["sleep-nested"], "Nested cycle records should be discovered under wrapper objects.")
        expect(nestedActivities.first?.sourceUpdatedAt == iso("2026-07-12T00:00:24.000Z"), "Nested cycle activity should parse epoch-string update timestamps.")
        expect(nestedActivities.first?.isNap == true, "Nested cycle activity should parse string nap markers.")

        let directSleepRecordsPayload = try json(
            """
            {
              "records": [
                {
                  "activityId": "sleep-direct",
                  "updatedAt": "2026-07-12T10:00:00.000Z",
                  "isNap": false
                },
                {
                  "id": "sleep-generic-id",
                  "type": "sleep",
                  "modified_at": "2026-07-12T11:00:00.000Z",
                  "sleep_type": "nap"
                },
                {
                  "id": "cycle-only",
                  "type": "cycle"
                }
              ]
            }
            """
        )
        let directActivities = WhoopPayloadAdapters.sleepActivities(fromCyclesJSON: directSleepRecordsPayload)
        expect(directActivities.map(\.activityID) == ["sleep-direct", "sleep-generic-id"], "Direct sleep records should parse without treating generic cycle IDs as sleep activities.")
        expect(directActivities.first { $0.activityID == "sleep-direct" }?.sourceUpdatedAt == iso("2026-07-12T10:00:00.000Z"), "Direct activity records should parse updatedAt timestamps.")
        expect(directActivities.first { $0.activityID == "sleep-generic-id" }?.isNap == true, "Direct generic sleep records should parse nap markers.")
    }

    static func testWhoopSleepEventsPayloadParsing() throws {
        let activity = WhoopSleepActivity(
            activityID: "sleep-1",
            sourceUpdatedAt: iso("2026-07-12T09:00:00.000Z"),
            isNap: false
        )
        let sleepPayload = try json(
            """
            {
              "start_time": "2026-07-12T00:00:00.000Z",
              "end_time": "2026-07-12T01:00:00.000Z",
              "events": [
                {
                  "type": "LATENCY",
                  "start_time": "2026-07-11T23:55:00.000Z",
                  "end_time": "2026-07-12T00:00:00.000Z"
                },
                {
                  "type": "LIGHT",
                  "start_time": "2026-07-12T00:00:00.000Z",
                  "end_time": "2026-07-12T00:20:00.000Z"
                },
                {
                  "type": "SWS",
                  "start_time": "2026-07-12T00:20:00.000Z",
                  "end_time": "2026-07-12T00:40:00.000Z"
                },
                {
                  "type": "REM",
                  "start_time": "2026-07-12T00:40:00.000Z",
                  "end_time": "2026-07-12T00:50:00.000Z"
                },
                {
                  "type": "WAKE",
                  "start_time": "2026-07-12T00:50:00.000Z",
                  "end_time": "2026-07-12T01:00:00.000Z"
                }
              ]
            }
            """
        )

        let session = try WhoopPayloadAdapters.sleepSession(fromSleepEventsJSON: sleepPayload, activity: activity)
        expect(session.whoopSleepID == "sleep-1", "Sleep session ID should come from activity ID.")
        expect(session.start == iso("2026-07-12T00:00:00.000Z"), "Sleep session start should parse from root payload.")
        expect(session.end == iso("2026-07-12T01:00:00.000Z"), "Sleep session end should parse from root payload.")
        expect(session.stages.map(\.stage) == [.core, .deep, .rem, .awake], "WHOOP stage labels should map to HealthKit domain stages.")
        expect(session.stages.map(\.range) == [
            TimeRange(start: iso("2026-07-12T00:00:00.000Z"), end: iso("2026-07-12T00:20:00.000Z")),
            TimeRange(start: iso("2026-07-12T00:20:00.000Z"), end: iso("2026-07-12T00:40:00.000Z")),
            TimeRange(start: iso("2026-07-12T00:40:00.000Z"), end: iso("2026-07-12T00:50:00.000Z")),
            TimeRange(start: iso("2026-07-12T00:50:00.000Z"), end: iso("2026-07-12T01:00:00.000Z"))
        ], "Sleep events should produce exact stage intervals.")

        let postgresRangePayload = try json(
            """
            [
              {
                "during": "['2026-07-12T21:38:00.340Z','2026-07-12T21:49:57.340Z')",
                "type": "LIGHT"
              },
              {
                "during": "['2026-07-12T21:49:57.340Z','2026-07-12T22:32:31.320Z')",
                "type": "SWS"
              },
              {
                "during": "['2026-07-12T22:32:31.320Z','2026-07-12T22:33:32.320Z')",
                "type": "DISTURBANCES"
              },
              {
                "during": "['2026-07-12T22:33:32.320Z','2026-07-12T22:35:32.320Z')",
                "type": "REM"
              }
            ]
            """
        )
        let postgresRangeSession = try WhoopPayloadAdapters.sleepSession(fromSleepEventsJSON: postgresRangePayload, activity: activity)
        expect(postgresRangeSession.start == iso("2026-07-12T21:38:00.340Z"), "Postgres-style WHOOP event ranges should provide the session start.")
        expect(postgresRangeSession.end == iso("2026-07-12T22:35:32.320Z"), "Postgres-style WHOOP event ranges should provide the session end.")
        expect(postgresRangeSession.stages.map(\.stage) == [.core, .deep, .rem], "Postgres-style WHOOP sleep-events should ignore non-sleep disturbance markers.")
        expect(postgresRangeSession.stages.map(\.range) == [
            TimeRange(start: iso("2026-07-12T21:38:00.340Z"), end: iso("2026-07-12T21:49:57.340Z")),
            TimeRange(start: iso("2026-07-12T21:49:57.340Z"), end: iso("2026-07-12T22:32:31.320Z")),
            TimeRange(start: iso("2026-07-12T22:33:32.320Z"), end: iso("2026-07-12T22:35:32.320Z"))
        ], "Postgres-style WHOOP sleep-events should preserve exact interval bounds.")

        let deepDivePayload = try json(
            """
            {
              "started_at": "2026-07-12T23:38:00.000+02:00",
              "ended_at": "2026-07-13T00:08:00.000+02:00",
              "hypnogram": [
                {
                  "stage": "LIGHT",
                  "started_at": "2026-07-12T23:38:00.000+02:00",
                  "ended_at": "2026-07-12T23:48:00.000+02:00"
                },
                {
                  "stage": "SWS",
                  "started_at": "2026-07-12T23:48:00.000+02:00",
                  "ended_at": "2026-07-12T23:58:00.000+02:00"
                },
                {
                  "stage": "AWAKE",
                  "started_at": "2026-07-12T23:58:00.000+02:00",
                  "ended_at": "2026-07-13T00:08:00.000+02:00"
                }
              ]
            }
            """
        )
        let deepDiveSession = try WhoopPayloadAdapters.sleepSession(fromSleepEventsJSON: deepDivePayload, activity: activity)
        expect(deepDiveSession.stages.map(\.stage) == [.core, .deep, .awake], "Deep-dive hypnogram should parse LIGHT/SWS/AWAKE stages.")
        expect(deepDiveSession.start == iso("2026-07-12T21:38:00.000Z"), "Deep-dive started_at should parse with timezone offset.")

        let nestedActivity = WhoopSleepActivity(activityID: "nested-sleep", sourceUpdatedAt: nil, isNap: false)
        let nestedPayload = try json(
            """
            {
              "data": {
                "sleep": {
                  "startTime": "2026-07-13T00:00:00.000Z",
                  "endTime": "2026-07-13T00:30:00.000Z",
                  "updatedAt": "2026-07-13T08:00:00.000Z",
                  "stages": [
                    {
                      "sleepStage": "core sleep",
                      "startTime": "2026-07-13T00:00:00.000Z"
                    },
                    {
                      "sleepStage": "slow-wave sleep",
                      "startTime": "2026-07-13T00:10:00.000Z"
                    },
                    {
                      "sleepStage": "asleep-rem",
                      "startTime": "2026-07-13T00:20:00.000Z"
                    }
                  ]
                }
              }
            }
            """
        )
        let nestedSession = try WhoopPayloadAdapters.sleepSession(fromSleepEventsJSON: nestedPayload, activity: nestedActivity)
        expect(nestedSession.start == iso("2026-07-13T00:00:00.000Z"), "Nested sleep payload should use nested root start.")
        expect(nestedSession.end == iso("2026-07-13T00:30:00.000Z"), "Nested sleep payload should use nested root end.")
        expect(nestedSession.sourceUpdatedAt == iso("2026-07-13T08:00:00.000Z"), "Nested sleep payload should use nested updatedAt when activity has none.")
        expect(nestedSession.stages.map(\.stage) == [.core, .deep, .rem], "Nested sleep payload should map normalized stage labels.")
        expect(nestedSession.stages.map(\.range) == [
            TimeRange(start: iso("2026-07-13T00:00:00.000Z"), end: iso("2026-07-13T00:10:00.000Z")),
            TimeRange(start: iso("2026-07-13T00:10:00.000Z"), end: iso("2026-07-13T00:20:00.000Z")),
            TimeRange(start: iso("2026-07-13T00:20:00.000Z"), end: iso("2026-07-13T00:30:00.000Z"))
        ], "Nested sleep parser should derive missing event ends from next event or nested root end.")

        let epochStringPayload = try json(
            """
            {
              "start_time": "1783814400000",
              "end_time": "1783814424000",
              "events": [
                {
                  "type": "LIGHT",
                  "start_time": "1783814400000",
                  "end_time": "1783814424000"
                }
              ]
            }
            """
        )
        let epochStringSession = try WhoopPayloadAdapters.sleepSession(fromSleepEventsJSON: epochStringPayload, activity: activity)
        expect(epochStringSession.start == iso("2026-07-12T00:00:00.000Z"), "Sleep parser should parse millisecond epoch strings.")
        expect(epochStringSession.end == iso("2026-07-12T00:00:24.000Z"), "Sleep parser should parse millisecond epoch string end times.")
    }

    static func testWhoopHeartRatePayloadParsing() throws {
        let hrPayload = try json(
            """
            {
              "values": [
                {"time": "2026-07-12T00:00:06.000Z", "data": 61},
                {"time": "2026-07-12T00:00:00.000Z", "data": "60"},
                {"time": "2026-07-12T00:00:12.000Z", "data": null},
                {"time": "2026-07-12T00:00:18.000Z", "data": -1},
                {"time": "1783814424000", "data": 64}
              ]
            }
            """
        )

        let points = try WhoopPayloadAdapters.heartRatePoints(fromJSON: hrPayload, stepSeconds: 6)
        expect(points.count == 3, "HR parser should ignore null and non-positive values.")
        expect(points.map(\.timestamp) == [iso("2026-07-12T00:00:00.000Z"), iso("2026-07-12T00:00:06.000Z"), iso("2026-07-12T00:00:24.000Z")], "HR points should parse ISO and epoch-string timestamps, then sort by timestamp.")
        expect(points.map(\.bpm) == [60, 61, 64], "HR parser should parse numeric strings and numbers.")
        expect(points.allSatisfy { $0.sourceStepSeconds == 6 }, "HR parser should keep source resolution.")

        let rootArrayPayload = try json(
            """
            [
              {"timestamp": "2026-07-12T00:03:00.000Z", "heartRate": 65},
              {"start": "2026-07-12T00:03:06.000Z", "value": {"bpm": "66"}},
              {"timestamp": "2026-07-12T00:03:12.000Z", "data": 0}
            ]
            """
        )
        let rootArrayPoints = try WhoopPayloadAdapters.heartRatePoints(fromJSON: rootArrayPayload, stepSeconds: 6)
        expect(rootArrayPoints.map(\.timestamp) == [iso("2026-07-12T00:03:00.000Z"), iso("2026-07-12T00:03:06.000Z")], "Root-array HR payload should parse direct point arrays.")
        expect(rootArrayPoints.map(\.bpm) == [65, 66], "Root-array HR payload should parse direct and nested bpm values.")

        let nestedPayload = try json(
            """
            {
              "metrics": [
                {
                  "name": "heart_rate",
                  "values": [
                    {
                      "timestamp": "2026-07-12T00:01:00.000Z",
                      "data": {"heart_rate": 62}
                    },
                    {
                      "started_at": "2026-07-12T00:02:00.000Z",
                      "value": {"bpm": "63"}
                    }
                  ]
                }
              ]
            }
            """
        )

        let nestedPoints = try WhoopPayloadAdapters.heartRatePoints(fromJSON: nestedPayload, stepSeconds: 60)
        expect(nestedPoints.map(\.timestamp) == [iso("2026-07-12T00:01:00.000Z"), iso("2026-07-12T00:02:00.000Z")], "Nested HR payload should parse timestamps.")
        expect(nestedPoints.map(\.bpm) == [62, 63], "Nested HR payload should parse bpm values.")
        expect(nestedPoints.allSatisfy { $0.sourceStepSeconds == 60 }, "Nested HR parser should keep effective source resolution.")
    }

    static func testDeterministicSyncIdentifiers() throws {
        let sleepID = SyncIdentifiers.sleep(
            whoopSleepID: "sleep-1",
            stage: .rem,
            start: iso("2026-07-12T00:40:00.000Z"),
            end: iso("2026-07-12T00:50:00.000Z")
        )
        expect(sleepID == "sleep:sleep-1:rem:1783816800000:1783817400000", "Sleep sync identifier should be deterministic.")

        let heartRateID = SyncIdentifiers.heartRate(
            timestamp: iso("2026-07-12T00:00:06.000Z"),
            stepSeconds: 6
        )
        expect(heartRateID == "heart-rate:1783814406000:6", "Heart-rate sync identifier should be deterministic.")
    }

    static func testMigrationSleepWritesOnlyGapsThenBecomesIdempotent() throws {
        let appleWatchEra = try normalizedSession(
            id: "apple-era-whoop-sleep",
            start: 0,
            end: 120,
            stages: [
                stage(0, 60, .core),
                stage(60, 120, .rem)
            ]
        )
        let appleCovered = [
            ExistingSleepSample(
                id: "apple-detailed-night",
                range: range(0, 120),
                value: .asleepCore,
                isOwnedByApp: false,
                whoopSleepID: nil,
                syncIdentifier: nil
            )
        ]
        let appleEraPlan = SleepCoverageReconciler.plan(
            session: appleWatchEra,
            existingSamples: appleCovered,
            fingerprintChanged: false
        )
        expect(appleEraPlan.fragmentsToWrite.isEmpty, "Apple Watch detailed sleep should block WHOOP sleep writes.")

        let whoopEraWithGenericHealthData = try normalizedSession(
            id: "whoop-era-sleep",
            start: 1_000,
            end: 1_120,
            stages: [
                stage(1_000, 1_060, .core),
                stage(1_060, 1_120, .deep)
            ]
        )
        let genericOnly = [
            ExistingSleepSample(
                id: "whoop-official-generic",
                range: range(1_000, 1_120),
                value: .asleepUnspecified,
                isOwnedByApp: false,
                whoopSleepID: nil,
                syncIdentifier: nil
            )
        ]
        let firstPlan = SleepCoverageReconciler.plan(
            session: whoopEraWithGenericHealthData,
            existingSamples: genericOnly,
            fingerprintChanged: false
        )
        expect(firstPlan.fragmentsToWrite.map(\.interval.range) == [range(1_000, 1_060), range(1_060, 1_120)], "Generic sleep should allow detailed WHOOP stages.")

        let ownSamplesAfterFirstSync = firstPlan.fragmentsToWrite.enumerated().map { offset, fragment in
            ExistingSleepSample(
                id: "own-\(offset)",
                range: fragment.interval.range,
                value: existingSleepValue(for: fragment.interval.stage),
                isOwnedByApp: true,
                whoopSleepID: fragment.whoopSleepID,
                syncIdentifier: SyncIdentifiers.sleep(
                    whoopSleepID: fragment.whoopSleepID,
                    stage: fragment.interval.stage,
                    start: fragment.interval.range.start,
                    end: fragment.interval.range.end
                )
            )
        }
        let secondPlan = SleepCoverageReconciler.plan(
            session: whoopEraWithGenericHealthData,
            existingSamples: genericOnly + ownSamplesAfterFirstSync,
            fingerprintChanged: false
        )
        expect(secondPlan.fragmentsToWrite.isEmpty, "Second sleep sync should be idempotent after app-owned samples exist.")
        expect(secondPlan.ownSamplesToDelete.isEmpty, "Second sleep sync should not delete current app-owned samples.")
    }

    static func testMigrationHeartRateWritesOnlyUncoveredBucketsThenBecomesIdempotent() {
        let points = [
            HeartRatePoint(timestamp: date(0), bpm: 60, sourceStepSeconds: 6),
            HeartRatePoint(timestamp: date(6), bpm: 61, sourceStepSeconds: 6),
            HeartRatePoint(timestamp: date(12), bpm: 62, sourceStepSeconds: 6),
            HeartRatePoint(timestamp: date(18), bpm: 63, sourceStepSeconds: 6)
        ]
        let appleWatchSamples = [
            ExistingHeartRateSample(id: "apple-0", range: range(0, 6), bpm: 59, isOwnedByApp: false, syncIdentifier: nil),
            ExistingHeartRateSample(id: "apple-6", range: range(6, 12), bpm: 61, isOwnedByApp: false, syncIdentifier: nil)
        ]

        let firstPlan = HeartRateCoverageReconciler.plan(
            points: points,
            existingSamples: appleWatchSamples,
            stepSeconds: 6
        )
        expect(firstPlan.pointsToWrite.map(\.timestamp) == [date(12), date(18)], "HR should write only WHOOP buckets not already covered by Apple Watch.")
        expect(firstPlan.skippedPointCount == 2, "HR should skip Apple-covered buckets.")

        let ownSamplesAfterFirstSync = firstPlan.pointsToWrite.map { point in
            ExistingHeartRateSample(
                id: "own-\(SyncIdentifiers.unixMilliseconds(point.timestamp))",
                range: HeartRateCoverageReconciler.bucket(for: point, stepSeconds: 6, semantics: .bucketStart),
                bpm: point.bpm,
                isOwnedByApp: true,
                syncIdentifier: SyncIdentifiers.heartRate(timestamp: point.timestamp, stepSeconds: 6)
            )
        }
        let secondPlan = HeartRateCoverageReconciler.plan(
            points: points,
            existingSamples: appleWatchSamples + ownSamplesAfterFirstSync,
            stepSeconds: 6
        )
        expect(secondPlan.pointsToWrite.isEmpty, "Second HR sync should be idempotent.")
        expect(secondPlan.ownSamplesToDelete.isEmpty, "Second HR sync should not delete equivalent app-owned samples.")
        expect(secondPlan.skippedPointCount == 4, "Second HR sync should account for all buckets as covered.")
    }

    static func testWhoopSleepRevisionDeletesOnlyOwnSamplesAndRewritesGaps() throws {
        let revisedSession = try normalizedSession(
            id: "revised-sleep",
            start: 0,
            end: 120,
            stages: [
                stage(0, 60, .deep),
                stage(60, 120, .rem)
            ]
        )
        let existing = [
            ExistingSleepSample(
                id: "own-old-1",
                range: range(0, 60),
                value: .asleepCore,
                isOwnedByApp: true,
                whoopSleepID: "revised-sleep",
                syncIdentifier: "old-1"
            ),
            ExistingSleepSample(
                id: "own-old-2",
                range: range(60, 120),
                value: .asleepDeep,
                isOwnedByApp: true,
                whoopSleepID: "revised-sleep",
                syncIdentifier: "old-2"
            ),
            ExistingSleepSample(
                id: "apple-middle",
                range: range(30, 90),
                value: .asleepREM,
                isOwnedByApp: false,
                whoopSleepID: nil,
                syncIdentifier: nil
            )
        ]

        let plan = SleepCoverageReconciler.plan(
            session: revisedSession,
            existingSamples: existing,
            fingerprintChanged: true
        )

        expect(plan.ownSamplesToDelete.map(\.id).sorted() == ["own-old-1", "own-old-2"], "WHOOP revision should delete only app-owned samples for that sleep.")
        expect(plan.fragmentsToWrite.map(\.interval.range) == [range(0, 30), range(90, 120)], "WHOOP revision should rewrite only gaps not covered by external detailed data.")
        expect(plan.fragmentsToWrite.map(\.interval.stage) == [.deep, .rem], "WHOOP revision should preserve revised stages on rewritten gaps.")
    }

    static func testWhoopSleepRevisionUsesHealthKitFingerprintWhenRepositoryIsMissing() throws {
        let oldSession = try normalizedSession(
            id: "metadata-revised-sleep",
            start: 0,
            end: 120,
            stages: [
                stage(0, 60, .core),
                stage(60, 120, .rem)
            ]
        )
        let currentSession = try normalizedSession(
            id: "metadata-revised-sleep",
            start: 0,
            end: 120,
            stages: [
                stage(0, 60, .deep),
                stage(60, 120, .rem)
            ]
        )
        let staleFingerprint = SleepFingerprint.make(for: oldSession)
        let existing = oldSession.stages.enumerated().map { offset, interval in
            ExistingSleepSample(
                id: "own-stale-\(offset)",
                range: interval.range,
                value: existingSleepValue(for: interval.stage),
                isOwnedByApp: true,
                whoopSleepID: oldSession.whoopSleepID,
                whoopSleepFingerprint: staleFingerprint,
                syncIdentifier: "old-\(offset)"
            )
        }

        let plan = SleepCoverageReconciler.plan(
            session: currentSession,
            existingSamples: existing,
            fingerprintChanged: false
        )

        expect(plan.ownSamplesToDelete.map(\.id).sorted() == ["own-stale-0", "own-stale-1"], "Stale HealthKit sleep fingerprint should trigger deletion even when repository did not flag a revision.")
        expect(plan.fragmentsToWrite.map(\.interval.stage) == [.deep, .rem], "Current revised stages should be rewritten after stale metadata deletion.")
    }

    static func testWhoopSleepFallbackIDMigrationUsesFingerprint() throws {
        let fallbackSession = try normalizedSession(
            id: "deep-dive-sleep:2026-07-12",
            start: 0,
            end: 120,
            stages: [
                stage(0, 60, .core),
                stage(60, 120, .rem)
            ]
        )
        let realSameSession = try normalizedSession(
            id: "real-activity-id",
            start: 0,
            end: 120,
            stages: [
                stage(0, 60, .core),
                stage(60, 120, .rem)
            ]
        )
        let fallbackFingerprint = SleepFingerprint.make(for: fallbackSession)
        let sameFingerprintSamples = fallbackSession.stages.enumerated().map { offset, interval in
            ExistingSleepSample(
                id: "fallback-own-\(offset)",
                range: interval.range,
                value: existingSleepValue(for: interval.stage),
                isOwnedByApp: true,
                whoopSleepID: fallbackSession.whoopSleepID,
                whoopSleepFingerprint: fallbackFingerprint,
                syncIdentifier: "fallback-\(offset)"
            )
        }
        let samePlan = SleepCoverageReconciler.plan(
            session: realSameSession,
            existingSamples: sameFingerprintSamples,
            fingerprintChanged: false
        )
        expect(samePlan.ownSamplesToDelete.isEmpty, "Fallback-owned samples with the same hypnogram should not be deleted when a real activity ID appears.")
        expect(samePlan.fragmentsToWrite.isEmpty, "Fallback-owned samples with the same hypnogram should block duplicate writes for the real activity ID.")

        let realRevisedSession = try normalizedSession(
            id: "real-activity-id",
            start: 0,
            end: 120,
            stages: [
                stage(0, 60, .deep),
                stage(60, 120, .rem)
            ]
        )
        let revisedPlan = SleepCoverageReconciler.plan(
            session: realRevisedSession,
            existingSamples: sameFingerprintSamples,
            fingerprintChanged: false
        )
        expect(revisedPlan.ownSamplesToDelete.map(\.id).sorted() == ["fallback-own-0", "fallback-own-1"], "Fallback-owned samples with stale hypnogram fingerprint should be deleted when the real activity ID returns a revision.")
        expect(revisedPlan.fragmentsToWrite.map(\.interval.stage) == [.deep, .rem], "Revised real activity should rewrite current stages after stale fallback samples are removed.")
    }

    static func testUnrelatedOwnSleepIsNotDeletedByCrossIDRevision() throws {
        let currentSession = try normalizedSession(
            id: "real-current-sleep",
            start: 0,
            end: 120,
            stages: [
                stage(0, 60, .deep),
                stage(60, 120, .rem)
            ]
        )
        let unrelatedSession = try normalizedSession(
            id: "real-unrelated-sleep",
            start: 0,
            end: 60,
            stages: [
                stage(0, 60, .core)
            ]
        )
        let unrelatedSample = ExistingSleepSample(
            id: "unrelated-own",
            range: range(0, 60),
            value: .asleepCore,
            isOwnedByApp: true,
            whoopSleepID: unrelatedSession.whoopSleepID,
            whoopSleepFingerprint: SleepFingerprint.make(for: unrelatedSession),
            syncIdentifier: "unrelated-own-sync"
        )

        let plan = SleepCoverageReconciler.plan(
            session: currentSession,
            existingSamples: [unrelatedSample],
            fingerprintChanged: false
        )

        expect(plan.ownSamplesToDelete.isEmpty, "A different real WHOOP sleep ID should not be deleted merely because it overlaps and has a different fingerprint.")
        expect(plan.fragmentsToWrite.map(\.interval.range) == [range(60, 120)], "Unrelated own coverage should still block overlapping duplicate writes without being deleted.")
        expect(plan.fragmentsToWrite.map(\.interval.stage) == [.rem], "Only uncovered stages should be written when unrelated own coverage exists.")
    }

    static func testSyncSummaryMergeCombinesCountersAndErrors() {
        var base = SyncSummary()
        base.sleepsDownloaded = 1
        base.sleepsDiscardedOutOfWindow = 1
        base.stagesWritten = 2
        base.errors = ["sleep-warning"]

        var other = SyncSummary()
        other.sleepsDownloaded = 3
        other.sleepsDiscardedOutOfWindow = 2
        other.heartRateWritten = 4
        other.heartRateDiscardedOutOfWindow = 5
        other.effectiveHeartRateResolution = 6
        other.errors = ["hr-warning"]

        base.merge(other)

        expect(base.sleepsDownloaded == 4, "Merged summary should add sleep counters.")
        expect(base.sleepsDiscardedOutOfWindow == 3, "Merged summary should add out-of-window sleep counters.")
        expect(base.stagesWritten == 2, "Merged summary should preserve existing counters.")
        expect(base.heartRateWritten == 4, "Merged summary should add HR counters.")
        expect(base.heartRateDiscardedOutOfWindow == 5, "Merged summary should add out-of-window HR counters.")
        expect(base.effectiveHeartRateResolution == 6, "Merged summary should carry effective HR resolution.")
        expect(base.errors == ["sleep-warning", "hr-warning"], "Merged summary should preserve error order.")
    }

    static func normalizedSession(stages: [SleepStageInterval]) throws -> SleepSession {
        try normalizedSession(id: "sleep-1", start: 0, end: 120, stages: stages)
    }

    static func normalizedSession(id: String, start: TimeInterval, end: TimeInterval, stages: [SleepStageInterval]) throws -> SleepSession {
        try SleepNormalizer.normalize(
            SleepSession(
                whoopSleepID: id,
                sourceUpdatedAt: nil,
                start: date(start),
                end: date(end),
                timezoneOffsetSeconds: nil,
                isNap: false,
                stages: stages
            )
        )
    }

    static func stage(_ start: TimeInterval, _ end: TimeInterval, _ sleepStage: SleepStage) -> SleepStageInterval {
        SleepStageInterval(start: date(start), end: date(end), stage: sleepStage)
    }

    static func range(_ start: TimeInterval, _ end: TimeInterval) -> TimeRange {
        TimeRange(start: date(start), end: date(end))
    }

    static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    static func existingSleepValue(for stage: SleepStage) -> ExistingSleepValue {
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

    static func iso(_ value: String) -> Date {
        guard let date = WhoopDateCodec.date(from: value) else {
            fatalError("Invalid ISO fixture date: \(value)")
        }
        return date
    }

    static func json(_ string: String) throws -> Any {
        let data = Data(string.utf8)
        return try JSONSerialization.jsonObject(with: data, options: [])
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}
