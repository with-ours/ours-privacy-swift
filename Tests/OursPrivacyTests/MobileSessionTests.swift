import Foundation
import XCTest
@testable import OursPrivacyKit

final class MobileSessionTests: XCTestCase {
    private let origin: Int64 = 1_791_194_400_000
    private var names: [String] = []

    override func tearDown() {
        let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)
        for name in names {
            defaults?.removeObject(forKey: "oursprivacy-\(name)-OPMobileSession")
        }
        names.removeAll()
        super.tearDown()
    }

    private func makeSession(_ name: String? = nil) -> MobileSession {
        let instanceName = name ?? "mobile-session-\(UUID().uuidString)"
        names.append(instanceName)
        return MobileSession(instanceName: instanceName)
    }

    private func point(_ elapsedMs: Int64, wallMs: Int64? = nil) -> MobileTimePoint {
        MobileTimePoint(epochMs: wallMs ?? origin + elapsedMs, monotonicMs: elapsedMs)
    }

    func testFirstEligibleForegroundHasOneSessionAndDuplicateIsEmpty() {
        let session = makeSession()
        let facts = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                       appVersion: "2.3", appBuild: "45", at: point(0))

        XCTAssertEqual(facts.map(\.name), ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start"])
        XCTAssertEqual(Set(facts.map(\.sid)).count, 1)
        XCTAssertEqual(facts[0].visitorId, "visitor-a")
        XCTAssertEqual(facts[0].appVersion, "2.3")
        XCTAssertEqual(facts[0].appBuild, "45")
        XCTAssertEqual(facts[0].occurredAtISO, "2026-10-05T10:00:00.000Z")
        XCTAssertEqual(facts[0].startedAtISO, "2026-10-05T10:00:00.000Z")
        XCTAssertEqual(facts[0].defaultProperties["mobile_contract_version"] as? Int, 1)
        XCTAssertTrue(session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0)).isEmpty)
    }

    func testBackgroundIdentityRotationStartsNextSessionAtNextActivityAcrossMidnight() {
        let session = makeSession()
        let late = point(13 * 60 * 60 * 1_000 + 59 * 60 * 1_000)
        let first = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: late)
        let firstSid = first[0].sid
        session.acknowledgeQueuedFacts(Set(first.map(\.distinctId)), firstOpenQueueEvidence: true)
        let inactive = point(14 * 60 * 60 * 1_000)
        _ = session.background(at: inactive)
        session.acknowledgeQueuedFacts(Set(session.pendingFacts.map(\.distinctId)),
                                       firstOpenQueueEvidence: true)
        let identityChange = point(14 * 60 * 60 * 1_000 + 60_000)
        _ = session.rotate(to: "visitor-b", appVersion: "3.0", appBuild: "2", at: identityChange)
        XCTAssertTrue(session.pendingFacts.isEmpty)

        let nextActivity = point(14 * 60 * 60 * 1_000 + 5 * 60_000)
        let reopened = session.foreground(automaticEnabled: true, visitorId: "visitor-b",
                                          appVersion: "3.0", appBuild: "2", at: nextActivity)
        let open = reopened.first { $0.name == "$mobile_app_open" }
        XCTAssertNotNil(open)
        XCTAssertNotEqual(open?.sid, firstSid)
        XCTAssertEqual(open?.startedAtMs, nextActivity.epochMs)
        XCTAssertEqual(open?.occurredAtMs, nextActivity.epochMs)
        XCTAssertFalse(reopened.contains { $0.name == "$mobile_first_open" })
    }

    func testInactivityBeforeAndAtThirtyMinutesRetainsThenRotatesSession() {
        let session = makeSession()
        let initial = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        let firstSid = initial[0].sid
        _ = session.background(at: point(10_000))

        let warm = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                      at: point(10_000 + 1_799_999))
        XCTAssertEqual(warm.map(\.name), ["$mobile_app_open"])
        XCTAssertEqual(warm[0].sid, firstSid)
        _ = session.background(at: point(1_810_000))

        let expired = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                         at: point(1_810_000 + 1_800_000))
        XCTAssertEqual(expired.map(\.name), ["$mobile_session_end", "$mobile_app_open", "$mobile_session_start"])
        XCTAssertEqual(expired[0].sid, firstSid)
        XCTAssertNotEqual(expired[1].sid, firstSid)
        XCTAssertEqual(expired[1].sid, expired[2].sid)
    }

    func testBackgroundUsesCapturedMonotonicTimeAndDoesNotDoubleCount() {
        let session = makeSession()
        _ = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))

        let facts = session.background(at: point(10_000, wallMs: origin + 120_000))

        XCTAssertEqual(facts.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(facts[0].properties["engagement_duration_ms"] as? Int64, 10_000)
        XCTAssertEqual(facts[0].occurredAtISO, "2026-10-05T10:02:00.000Z")
        XCTAssertTrue(session.background(at: point(20_000)).isEmpty)
    }

    func testInactiveResumeExcludesPausedTimeAndKeepsCumulativeThreshold() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))

        let paused = session.pauseActive(at: point(9_000))
        XCTAssertEqual(paused.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(paused.first?.properties["engagement_duration_ms"] as? Int64, 9_000)
        XCTAssertEqual(session.remainingEngagementThresholdMs, 1_000)
        XCTAssertTrue(session.checkpoint(at: point(1_900_000)).isEmpty)
        XCTAssertTrue(session.resumeActive(at: point(1_900_000)))
        XCTAssertFalse(session.resumeActive(at: point(1_900_000)))
        XCTAssertTrue(session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                         at: point(1_900_000)).isEmpty)
        XCTAssertTrue(session.checkpoint(at: point(1_900_999)).isEmpty)
        let boundary = session.checkpoint(at: point(1_901_000))
        XCTAssertEqual(boundary.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(boundary.first?.properties["engagement_duration_ms"] as? Int64, 1_000)
        XCTAssertEqual(boundary.first?.sid, opened.first?.sid)
        XCTAssertTrue(session.background(at: point(1_901_000)).isEmpty)
    }

    func testRealBackgroundAfterPauseAllowsOneWarmOpen() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        _ = session.pauseActive(at: point(9_000))
        XCTAssertTrue(session.background(at: point(60_000)).isEmpty)

        let warm = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(61_000))

        XCTAssertEqual(warm.map(\.name), ["$mobile_app_open"])
        XCTAssertEqual(warm.first?.sid, opened.first?.sid)
        XCTAssertTrue(session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                         at: point(61_000)).isEmpty)
        XCTAssertEqual(session.background(at: point(62_000)).first?
            .properties["engagement_duration_ms"] as? Int64, 1_000)
    }

    func testBackgroundTimeoutStartsAtPauseBoundary() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        _ = session.pauseActive(at: point(9_000))
        _ = session.background(at: point(60_000))

        let expired = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                         at: point(1_809_000))

        XCTAssertEqual(expired.map(\.name),
                       ["$mobile_session_end", "$mobile_app_open", "$mobile_session_start"])
        XCTAssertEqual(expired.first?.sid, opened.first?.sid)
        XCTAssertNotEqual(expired[1].sid, opened.first?.sid)
    }

    func testProcessRecreationReplaysPendingFirstOpenWithFrozenContext() {
        let name = "recreation-\(UUID().uuidString)"
        let first = makeSession(name)
        let generated = first.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                         appVersion: "2.3", appBuild: "45", at: point(0))[0]
        XCTAssertFalse(first.hasAcceptedFirstOpen)

        let restored = makeSession(name)
        let replay = restored.foreground(automaticEnabled: true, visitorId: "visitor-b",
                                         appVersion: "9.0", appBuild: "90", at: point(1_000))
        let firstOpens = replay.filter { $0.name == "$mobile_first_open" }

        XCTAssertEqual(firstOpens.count, 1)
        XCTAssertEqual(firstOpens[0].distinctId, generated.distinctId)
        XCTAssertEqual(firstOpens[0].visitorId, "visitor-a")
        XCTAssertEqual(firstOpens[0].appVersion, "2.3")
        XCTAssertEqual(firstOpens[0].appBuild, "45")
        XCTAssertEqual(firstOpens[0].sid, generated.sid)
        XCTAssertEqual(firstOpens[0].occurredAtISO, generated.occurredAtISO)
        XCTAssertEqual(firstOpens[0].startedAtISO, generated.startedAtISO)
        XCTAssertFalse(restored.hasAcceptedFirstOpen)
    }

    func testFirstOpenAcceptanceNeedsQueueEvidenceAndSurvivesIdentityRotation() {
        let session = makeSession()
        let first = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))[0]

        session.acknowledgeQueuedFacts([first.distinctId], firstOpenQueueEvidence: false)
        XCTAssertEqual(session.pendingFacts.first?.distinctId, first.distinctId)
        XCTAssertFalse(session.hasAcceptedFirstOpen)

        _ = session.rotate(at: point(1_000))
        XCTAssertEqual(session.pendingFacts.first?.distinctId, first.distinctId)
        session.acknowledgeQueuedFacts([first.distinctId], firstOpenQueueEvidence: true)
        XCTAssertTrue(session.hasAcceptedFirstOpen)
        XCTAssertFalse(session.pendingFacts.contains { $0.distinctId == first.distinctId })

        let reopened = session.foreground(automaticEnabled: true, visitorId: "visitor-b", at: point(2_000))
        XCTAssertEqual(reopened.map(\.name), ["$mobile_app_open", "$mobile_session_start"])
        XCTAssertNotEqual(reopened[0].sid, first.sid)
    }

    func testQueueEvidenceAfterOptOutStillPreventsAnotherFirstOpen() {
        let name = "accepted-after-opt-out-\(UUID().uuidString)"
        let session = makeSession(name)
        let first = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))[0]
        session.disable()

        session.acknowledgeQueuedFacts([first.distinctId], firstOpenQueueEvidence: true)

        let restored = makeSession(name)
        XCTAssertTrue(restored.hasAcceptedFirstOpen)
        let reopened = restored.foreground(automaticEnabled: true, visitorId: "visitor-b", at: point(1_000))
        XCTAssertEqual(reopened.map(\.name), ["$mobile_app_open", "$mobile_session_start"])
    }

    func testOptOutBeforeEligibleOpenDoesNotConsumeFirstOpen() {
        let session = makeSession()
        XCTAssertTrue(session.foreground(automaticEnabled: false, visitorId: "visitor-a", at: point(0)).isEmpty)
        session.disable()
        XCTAssertFalse(session.hasAcceptedFirstOpen)

        let reopened = session.foreground(automaticEnabled: true, visitorId: "visitor-b", at: point(1_000))
        XCTAssertEqual(reopened.map(\.name), ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start"])
        session.disable()
        XCTAssertTrue(session.pendingFacts.isEmpty)
        XCTAssertFalse(session.hasAcceptedFirstOpen)
    }

    func testAutomaticOptInDuringManualForegroundRecordsFirstAppOpen() {
        let session = makeSession()
        XCTAssertTrue(session.foreground(automaticEnabled: false, visitorId: "visitor-a", at: point(0)).isEmpty)

        let enabled = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(1_000))

        XCTAssertEqual(enabled.map(\.name), ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start"])
        XCTAssertTrue(session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(1_000)).isEmpty)
    }

    func testVersionChangeAfterRecreationProducesOneUpdateWithPreviousValues() {
        let name = "version-\(UUID().uuidString)"
        let first = makeSession(name)
        let opened = first.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                      appVersion: "2.3", appBuild: "45", at: point(0))
        XCTAssertFalse(opened.contains { $0.name == "$mobile_app_update" })
        first.acknowledgeQueuedFacts(Set(opened.map(\.distinctId)), firstOpenQueueEvidence: true)
        _ = first.background(at: point(10_000))

        let restored = makeSession(name)
        let changed = restored.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                          appVersion: "2.4", appBuild: "46", at: point(20_000))
        let updates = changed.filter { $0.name == "$mobile_app_update" }
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].properties["previous_app_version"] as? String, "2.3")
        XCTAssertEqual(updates[0].properties["previous_app_build"] as? String, "45")
        _ = restored.background(at: point(30_000))
        let unchanged = restored.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                            appVersion: "2.4", appBuild: "46", at: point(40_000))
        XCTAssertFalse(unchanged.contains { $0.name == "$mobile_app_update" })
    }

    func testUnavailableMetadataDoesNotEmitUpdateOrClearKnownBaseline() {
        let sessionName = "missing-build-\(UUID().uuidString)"
        let session = makeSession(sessionName)
        _ = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                               appVersion: "2.3", appBuild: "45", at: point(0))
        _ = session.background(at: point(10_000))

        let missingBuild = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                              appVersion: "2.3", appBuild: nil, at: point(20_000))
        XCTAssertFalse(missingBuild.contains { $0.name == "$mobile_app_update" })
        _ = session.background(at: point(30_000))

        let restored = makeSession(sessionName)
        let missingVersion = restored.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                                appVersion: nil, appBuild: "45", at: point(40_000))
        XCTAssertFalse(missingVersion.contains { $0.name == "$mobile_app_update" })
        _ = restored.background(at: point(50_000))

        let recovered = restored.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                            appVersion: "2.3", appBuild: "45", at: point(60_000))
        XCTAssertFalse(recovered.contains { $0.name == "$mobile_app_update" })
    }

    func testVersionChangeWithUnavailableBuildPreservesBuildBaseline() {
        let session = makeSession()
        _ = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                               appVersion: "2.3", appBuild: "45", at: point(0))
        _ = session.background(at: point(10_000))

        let changed = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                         appVersion: "2.4", appBuild: nil, at: point(20_000))
        let updates = changed.filter { $0.name == "$mobile_app_update" }
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.properties["previous_app_version"] as? String, "2.3")
        XCTAssertEqual(updates.first?.properties["previous_app_build"] as? String, "45")
        _ = session.background(at: point(30_000))

        let recovered = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                           appVersion: "2.4", appBuild: "45", at: point(40_000))
        XCTAssertFalse(recovered.contains { $0.name == "$mobile_app_update" })
    }

    func testManualSnapshotWithoutAutomaticTrackingCreatesSessionWithoutFacts() {
        let session = makeSession()
        let snapshot = session.snapshot(visitorId: "visitor-a", at: point(0))

        XCTAssertFalse(snapshot.sid.isEmpty)
        XCTAssertEqual(snapshot.startedAtISO, "2026-10-05T10:00:00.000Z")
        XCTAssertEqual(snapshot.occurredAtISO, "2026-10-05T10:00:00.000Z")
        XCTAssertTrue(session.pendingFacts.isEmpty)
        XCTAssertEqual(snapshot.defaultProperties["mobile_platform"] as? String, "ios")
        XCTAssertEqual(snapshot.defaultProperties["mobile_contract_version"] as? Int, 1)
        XCTAssertEqual(snapshot.defaultProperties["sid"] as? String, snapshot.sid)
    }

    func testCrossingUTCMidnightRetainsOriginalSessionStartDay() {
        let session = makeSession()
        let midnight = origin + 14 * 3_600_000
        let start = MobileTimePoint(epochMs: midnight - 10_000, monotonicMs: 0)
        let nextDay = MobileTimePoint(epochMs: midnight + 10_000, monotonicMs: 20_000)

        let initial = session.snapshot(visitorId: "visitor-a", at: start)
        let later = session.snapshot(visitorId: "visitor-a", at: nextDay)

        XCTAssertEqual(later.sid, initial.sid)
        XCTAssertEqual(later.startedAtISO, "2026-10-05T23:59:50.000Z")
        XCTAssertEqual(later.occurredAtISO, "2026-10-06T00:00:10.000Z")
    }

    func testWallRollbackBeyondFiveMinutesStartsSafeSession() {
        let session = makeSession()
        let first = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        _ = session.background(at: point(10_000))
        let rollback = MobileTimePoint(epochMs: origin - 300_001, monotonicMs: 20_000)

        let reopened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: rollback)

        XCTAssertNotEqual(reopened.last?.sid, first[0].sid)
        XCTAssertEqual(reopened.last?.occurredAtMs, rollback.epochMs)
        XCTAssertEqual(reopened.last?.startedAtMs, rollback.epochMs)
    }

    func testBackgroundRollbackPreservesMeasuredEngagementForOriginalSession() {
        let name = "background-rollback-\(UUID().uuidString)"
        let session = makeSession(name)
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                        appVersion: "2.3", appBuild: "45", at: point(0))
        let rollback = MobileTimePoint(epochMs: origin - 300_001, monotonicMs: 10_000)

        let facts = session.background(at: rollback)

        XCTAssertEqual(facts.map(\.name), ["$mobile_session_engagement"])
        guard let engagement = facts.first else { return }
        XCTAssertEqual(engagement.properties["engagement_duration_ms"] as? Int64, 10_000)
        XCTAssertEqual(engagement.sid, opened[0].sid)
        XCTAssertEqual(engagement.visitorId, "visitor-a")
        XCTAssertEqual(engagement.appVersion, "2.3")
        XCTAssertEqual(engagement.appBuild, "45")
        XCTAssertFalse(engagement.distinctId.isEmpty)
        XCTAssertGreaterThanOrEqual(engagement.occurredAtMs, engagement.startedAtMs)

        let restored = makeSession(name)
        let pending = restored.pendingFacts.first { $0.distinctId == engagement.distinctId }
        XCTAssertEqual(pending?.sid, engagement.sid)
        XCTAssertEqual(pending?.visitorId, engagement.visitorId)
        XCTAssertEqual(pending?.occurredAtMs, engagement.occurredAtMs)

        let next = restored.snapshot(visitorId: "visitor-b", at: rollback)
        XCTAssertNotEqual(next.sid, engagement.sid)
        XCTAssertEqual(next.occurredAtMs, rollback.epochMs)
    }

    func testScreenRollbackKeepsOldScreenEngagement() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        _ = session.screen("Schedule", visitorId: "visitor-a", at: point(1_000))
        let rollback = MobileTimePoint(epochMs: origin - 300_001, monotonicMs: 11_000)

        let facts = session.screen("Booking", visitorId: "visitor-b", at: rollback)

        XCTAssertEqual(facts.map(\.name), ["$mobile_session_engagement", "$mobile_screen_view"])
        guard facts.count == 2 else { return }
        XCTAssertEqual(facts[0].properties["engagement_duration_ms"] as? Int64, 10_000)
        XCTAssertEqual(facts[0].properties["screen_name"] as? String, "Schedule")
        XCTAssertEqual(facts[0].sid, opened[0].sid)
        XCTAssertEqual(facts[0].visitorId, "visitor-a")
        XCTAssertGreaterThanOrEqual(facts[0].occurredAtMs, facts[0].startedAtMs)
        XCTAssertNotEqual(facts[1].sid, opened[0].sid)
        XCTAssertEqual(facts[1].occurredAtMs, rollback.epochMs)
    }

    func testIdentityRotationDuringRollbackKeepsOldEngagement() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        let rollback = MobileTimePoint(epochMs: origin - 300_001, monotonicMs: 10_000)

        let facts = session.rotate(at: rollback)

        XCTAssertEqual(facts.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(facts.first?.sid, opened[0].sid)
        XCTAssertEqual(facts.first?.visitorId, "visitor-a")
        XCTAssertEqual(facts.first?.properties["engagement_duration_ms"] as? Int64, 10_000)
        XCTAssertGreaterThanOrEqual(facts.first?.occurredAtMs ?? 0, facts.first?.startedAtMs ?? 0)
        XCTAssertTrue(session.pendingFacts.contains { $0.distinctId == facts.first?.distinctId })
    }

    func testPeriodicCheckpointDuringRollbackKeepsOldEngagement() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        let rollback = MobileTimePoint(epochMs: origin - 300_001, monotonicMs: 10_000)

        let facts = session.checkpoint(at: rollback)

        XCTAssertEqual(facts.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(facts.first?.sid, opened[0].sid)
        XCTAssertEqual(facts.first?.properties["engagement_duration_ms"] as? Int64, 10_000)
        XCTAssertTrue(session.pendingFacts.contains { $0.distinctId == facts.first?.distinctId })
        let next = session.snapshot(visitorId: "visitor-b", at: rollback)
        XCTAssertNotEqual(next.sid, opened[0].sid)
    }

    func testManualSnapshotAfterRollbackPreservesOldForegroundEngagement() {
        let name = "manual-rollback-\(UUID().uuidString)"
        let session = makeSession(name)
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a",
                                        appVersion: "2.3", appBuild: "45", at: point(0))
        let rollback = MobileTimePoint(epochMs: origin - 300_001, monotonicMs: 10_000)

        let manual = session.snapshot(visitorId: "visitor-b", appVersion: "9.0",
                                      appBuild: "90", at: rollback)

        XCTAssertNotEqual(manual.sid, opened[0].sid)
        XCTAssertEqual(manual.startedAtMs, rollback.epochMs)
        XCTAssertEqual(manual.occurredAtMs, rollback.epochMs)
        XCTAssertEqual(manual.visitorId, "visitor-b")
        let engagements = session.pendingFacts.filter { $0.name == "$mobile_session_engagement" }
        XCTAssertEqual(engagements.count, 1)
        guard let engagement = engagements.first else { return }
        XCTAssertEqual(engagement.properties["engagement_duration_ms"] as? Int64, 10_000)
        XCTAssertEqual(engagement.sid, opened[0].sid)
        XCTAssertEqual(engagement.visitorId, "visitor-a")
        XCTAssertEqual(engagement.appVersion, "2.3")
        XCTAssertEqual(engagement.appBuild, "45")
        XCTAssertGreaterThanOrEqual(engagement.occurredAtMs, engagement.startedAtMs)
        XCTAssertFalse(engagement.distinctId.isEmpty)
        XCTAssertTrue(session.background(at: point(20_000, wallMs: rollback.epochMs)).isEmpty)

        let restored = makeSession(name)
        let pending = restored.pendingFacts.first { $0.distinctId == engagement.distinctId }
        XCTAssertEqual(pending?.sid, engagement.sid)
        XCTAssertEqual(pending?.visitorId, engagement.visitorId)
        XCTAssertEqual(pending?.occurredAtMs, engagement.occurredAtMs)
    }

    func testScheduleScreenReentryAfterWarmForegroundEmitsAnotherView() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        let firstView = session.screen("Schedule", visitorId: "visitor-a", at: point(0))
        XCTAssertEqual(firstView.map(\.name), ["$mobile_screen_view"])
        _ = session.background(at: point(10_000))
        let warmOpen = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(11_000))

        let reentry = session.screen("Schedule", visitorId: "visitor-a", at: point(11_000))

        XCTAssertEqual(warmOpen.map(\.name), ["$mobile_app_open"])
        XCTAssertEqual(reentry.map(\.name), ["$mobile_screen_view"])
        XCTAssertEqual(reentry.first?.sid, opened[0].sid)
        XCTAssertEqual(reentry.first?.properties["screen_name"] as? String, "Schedule")
        XCTAssertTrue(session.screen("Schedule", visitorId: "visitor-a", at: point(11_000)).isEmpty)
    }

    func testScheduleAsFirstSignalAtThirtyMinuteExpiryRotatesAndEmitsView() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        let firstOpenId = opened[0].distinctId
        _ = session.screen("Schedule", visitorId: "visitor-a", at: point(0))
        _ = session.background(at: point(10_000))

        let reentry = session.screen("Schedule", visitorId: "visitor-a", at: point(1_810_000))

        let views = reentry.filter { $0.name == "$mobile_screen_view" }
        XCTAssertEqual(views.count, 1)
        XCTAssertNotEqual(views.first?.sid, opened[0].sid)
        XCTAssertEqual(views.first?.properties["screen_name"] as? String, "Schedule")
        XCTAssertEqual(views.first?.occurredAtMs, origin + 1_810_000)
        XCTAssertTrue(session.pendingFacts.contains { $0.distinctId == firstOpenId })
        XCTAssertFalse(session.hasAcceptedFirstOpen)
    }

    func testScreenSwitchCheckpointsPriorScreenAndDeduplicatesName() {
        let session = makeSession()
        _ = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        let first = session.screen("Schedule", visitorId: "visitor-a", at: point(1_000))
        let duplicate = session.screen("Schedule", visitorId: "visitor-a", at: point(2_000))
        let second = session.screen("Booking", visitorId: "visitor-a", at: point(11_000))

        XCTAssertEqual(first.map(\.name), ["$mobile_session_engagement", "$mobile_screen_view"])
        XCTAssertTrue(duplicate.isEmpty)
        XCTAssertEqual(second.map(\.name), ["$mobile_session_engagement", "$mobile_screen_view"])
        XCTAssertEqual(second[0].properties["engagement_duration_ms"] as? Int64, 10_000)
        XCTAssertEqual(second[0].properties["screen_name"] as? String, "Schedule")
        XCTAssertEqual(second[1].properties["screen_name"] as? String, "Booking")
    }

    func testScreenDeltaContributesToNextPeriodicThresholdWithoutOverlap() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        _ = session.screen("Schedule", visitorId: "visitor-a", at: point(0))

        let changed = session.screen("Booking", visitorId: "visitor-a", at: point(9_000))
        XCTAssertEqual(changed.map(\.name), ["$mobile_session_engagement", "$mobile_screen_view"])
        XCTAssertTrue(session.checkpoint(at: point(9_999)).isEmpty)
        let boundary = session.checkpoint(at: point(10_000))
        XCTAssertEqual(boundary.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(changed[0].properties["engagement_duration_ms"] as? Int64, 9_000)
        XCTAssertEqual(changed[0].properties["screen_name"] as? String, "Schedule")
        XCTAssertEqual(boundary.first?.properties["engagement_duration_ms"] as? Int64, 1_000)
        XCTAssertEqual(boundary.first?.properties["screen_name"] as? String, "Booking")
        XCTAssertEqual(changed[0].sid, opened[0].sid)
        XCTAssertEqual(boundary.first?.sid, opened[0].sid)
        XCTAssertNotEqual(changed[0].distinctId, boundary.first?.distinctId)

        XCTAssertTrue(session.checkpoint(at: point(10_000)).isEmpty)
        XCTAssertTrue(session.checkpoint(at: point(19_999)).isEmpty)
        let next = session.checkpoint(at: point(20_000))
        XCTAssertEqual(next.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(next.first?.properties["engagement_duration_ms"] as? Int64, 10_000)
        XCTAssertTrue(session.background(at: point(20_000)).isEmpty)
    }

    func testCumulativeThresholdSurvivesProcessRecreation() {
        let name = "cumulative-recreation-\(UUID().uuidString)"
        let first = makeSession(name)
        let opened = first.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        _ = first.screen("Schedule", visitorId: "visitor-a", at: point(0))
        let changed = first.screen("Booking", visitorId: "visitor-a", at: point(9_000))
        XCTAssertEqual(changed[0].properties["engagement_duration_ms"] as? Int64, 9_000)

        let restored = makeSession(name)
        let reopened = restored.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(9_000))
        XCTAssertEqual(reopened.last?.sid, opened[0].sid)
        _ = restored.screen("Booking", visitorId: "visitor-a", at: point(9_000))
        let boundary = restored.checkpoint(at: point(10_000))
        XCTAssertEqual(boundary.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(boundary.first?.properties["engagement_duration_ms"] as? Int64, 1_000)
        XCTAssertEqual(boundary.first?.properties["screen_name"] as? String, "Booking")
        XCTAssertEqual(boundary.first?.sid, changed[0].sid)
        XCTAssertNotEqual(boundary.first?.distinctId, changed[0].distinctId)
        XCTAssertTrue(restored.checkpoint(at: point(10_000)).isEmpty)
    }

    func testBackgroundDeltaContributesToNextPeriodicThreshold() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        let background = session.background(at: point(9_000))
        XCTAssertEqual(background.first?.properties["engagement_duration_ms"] as? Int64, 9_000)

        let reopened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(10_000))
        XCTAssertEqual(reopened.map(\.name), ["$mobile_app_open"])
        let boundary = session.checkpoint(at: point(11_000))
        XCTAssertEqual(boundary.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(boundary.first?.properties["engagement_duration_ms"] as? Int64, 1_000)
        XCTAssertEqual(boundary.first?.sid, opened[0].sid)
        XCTAssertNotEqual(boundary.first?.distinctId, background[0].distinctId)
        XCTAssertTrue(session.background(at: point(11_000)).isEmpty)
    }

    func testFreshPeriodicCheckpointEmitsAtExactlyTenSeconds() {
        let session = makeSession()
        _ = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))

        XCTAssertTrue(session.checkpoint(at: point(9_999)).isEmpty)
        let boundary = session.checkpoint(at: point(10_000))
        XCTAssertEqual(boundary.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(boundary.first?.properties["engagement_duration_ms"] as? Int64, 10_000)
        XCTAssertTrue(session.checkpoint(at: point(10_000)).isEmpty)
    }

    func testOlderStoredSessionWithoutCumulativeFieldKeepsItsSession() {
        let name = "legacy-duration-\(UUID().uuidString)"
        let first = makeSession(name)
        let opened = first.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        _ = first.background(at: point(9_000))

        let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)
        let key = "oursprivacy-\(name)-OPMobileSession"
        guard let data = defaults?.data(forKey: key),
              var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("Expected stored session")
            return
        }
        stored.removeValue(forKey: "foregroundDurationMs")
        guard let olderData = try? JSONSerialization.data(withJSONObject: stored) else {
            XCTFail("Expected serializable session")
            return
        }
        defaults?.set(olderData, forKey: key)

        let restored = makeSession(name)
        let reopened = restored.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(10_000))
        XCTAssertEqual(reopened.last?.sid, opened[0].sid)
        let boundary = restored.checkpoint(at: point(20_000))
        XCTAssertEqual(boundary.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(boundary.first?.properties["engagement_duration_ms"] as? Int64, 10_000)
    }

    func testSessionRotationResetsCumulativeDuration() {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        let first = session.screen("Schedule", visitorId: "visitor-a", at: point(9_000))
        XCTAssertEqual(first[0].properties["engagement_duration_ms"] as? Int64, 9_000)

        _ = session.rotate(to: "visitor-b", appVersion: nil, appBuild: nil, at: point(9_000))
        let next = session.snapshot(visitorId: "visitor-b", at: point(9_000))
        XCTAssertNotEqual(next.sid, opened[0].sid)
        XCTAssertTrue(session.checkpoint(at: point(10_000)).isEmpty)
        let boundary = session.checkpoint(at: point(19_000))
        XCTAssertEqual(boundary.map(\.name), ["$mobile_session_engagement"])
        XCTAssertEqual(boundary.first?.properties["engagement_duration_ms"] as? Int64, 10_000)
        XCTAssertEqual(boundary.first?.sid, next.sid)
    }

    func testManualSessionAndOptOutDoNotEmitAutomaticEngagement() {
        let session = makeSession()
        XCTAssertTrue(session.foreground(automaticEnabled: false, visitorId: "visitor-a", at: point(0)).isEmpty)
        XCTAssertEqual(session.screen("Schedule", visitorId: "visitor-a", at: point(9_000)).map(\.name),
                       ["$mobile_screen_view"])
        XCTAssertTrue(session.checkpoint(at: point(10_000)).isEmpty)
        XCTAssertTrue(session.background(at: point(20_000)).isEmpty)
        session.disable()
        XCTAssertTrue(session.checkpoint(at: point(30_000)).isEmpty)
        XCTAssertTrue(session.background(at: point(30_000)).isEmpty)
        XCTAssertFalse(session.pendingFacts.contains { $0.name == "$mobile_session_engagement" })
    }

    func testExplicitScreenAdvancesInactivityBoundaryWithoutAutomaticLifecycle() {
        let session = makeSession()
        let first = session.screen("Schedule", visitorId: "visitor-a", at: point(0))[0]
        XCTAssertEqual(first.name, "$mobile_screen_view")
        XCTAssertEqual(session.pendingFacts.map(\.name), ["$mobile_screen_view"])

        let expired = session.snapshot(visitorId: "visitor-a", at: point(1_800_000))
        XCTAssertNotEqual(expired.sid, first.sid)
        XCTAssertFalse(session.pendingFacts.contains { $0.name == "$mobile_app_open" })

        let active = makeSession()
        let initial = active.snapshot(visitorId: "visitor-a", at: point(0))
        _ = active.screen("Schedule", visitorId: "visitor-a", at: point(600_000))
        let retained = active.snapshot(visitorId: "visitor-a", at: point(1_800_000))
        XCTAssertEqual(retained.sid, initial.sid)
    }
}

extension OursPrivacyTests {
    func heldActiveOptIn(failingWrites: Int = 2, withIdentify: Bool = false) async
        -> (OursPrivacy, MobileTimePoint) {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let point = MobileTimePoint(epochMs: 1_791_194_400_000, monotonicMs: 0)
        op.captureMobileTime = { point }
        op.mobileQueueNowMs = { point.epochMs + 20_000 }
        op.mobilePendingRetryIntervalMs = 60_000
        op.mobileForeground(at: point)
        op.trackingQueue.sync {}
        let persist = op.oursprivacyPersistence.persistenceWrite
        var failures = 0
        op.oursprivacyPersistence.persistenceWrite = { data in
            if failures < failingWrites {
                failures += 1
                return false
            }
            return persist(data)
        }
        op.optInTracking(userProperties: withIdentify
            ? OursPrivacyUserProperties(externalId: "external-1") : nil)
        op.trackingQueue.sync {}
        return (op, point)
    }

    func testHeldOptInPrecedesLaterScreenThenManualTrack() async {
        let (op, point) = await heldActiveOptIn(failingWrites: 3, withIdentify: true)
        op.trackScreen("Schedule")
        op.track(event: "Blue")
        op.trackingQueue.sync {}
        op.mobilePause(at: MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: 1_000))
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start",
                        "$identify", "$opt_in", "$mobile_screen_view", "Blue", "$mobile_session_engagement"])
        XCTAssertEqual((events[5]["eventProperties"] as? [String: Any])?["screen_name"] as? String, "Schedule")
        XCTAssertEqual((events.last?["eventProperties"] as? [String: Any])?["screen_name"] as? String,
                       "Schedule")
        XCTAssertEqual((events.last?["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int64,
                       1_000)
        let sid = (events.first?["defaultProperties"] as? [String: Any])?["sid"] as? String
        XCTAssertNotNil(sid)
        XCTAssertTrue(events.allSatisfy {
            ($0["defaultProperties"] as? [String: Any])?["sid"] as? String == sid
        })
        XCTAssertTrue(events.allSatisfy { $0["visitor_id"] as? String == op.visitorId })
    }

    func testHeldOptInPrecedesManualTrackThenLaterScreen() async {
        let (op, point) = await heldActiveOptIn(failingWrites: 5)
        op.track(event: "Blue")
        op.trackScreen("Schedule")
        op.trackingQueue.sync {}
        op.mobileForeground(at: MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: 1_000))
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start",
                        "$opt_in", "Blue", "$mobile_screen_view"])
        XCTAssertEqual((events.last?["eventProperties"] as? [String: Any])?["screen_name"] as? String,
                       "Schedule")
    }

    func testLaterScreenRemainsDurablyPendingBehindHeldOptIn() async {
        let (op, point) = await heldActiveOptIn(failingWrites: 20)
        op.trackScreen("Schedule")
        op.trackingQueue.sync {}
        let restored = MobileSession(instanceName: op.name)
        XCTAssertTrue(restored.pendingFacts.contains {
            $0.name == "$mobile_screen_view" && $0.properties["screen_name"] as? String == "Schedule"
        })
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        let persist = OursPrivacyPersistence(instanceName: op.name).persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = persist
        op.mobileForeground(at: MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: 1_000))
        op.trackingQueue.sync {}
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start",
                        "$opt_in", "$mobile_screen_view"])
    }

    func testForcedPauseEngagementFollowsHeldOptIn() async {
        let (op, point) = await heldActiveOptIn()
        op.mobilePause(at: MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: 1_000))
        op.trackingQueue.sync {}
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start",
                        "$opt_in", "$mobile_session_engagement"])
        XCTAssertEqual((events.last?["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int64,
                       1_000)
    }

    func testBackgroundAndWarmOpenFollowHeldOptInWithoutDuplicateStart() async {
        let (op, point) = await heldActiveOptIn(failingWrites: 3)
        op.mobileBackground(at: MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: 1_000))
        op.mobileForeground(at: MobileTimePoint(epochMs: point.epochMs + 2_000, monotonicMs: 2_000))
        op.trackingQueue.sync {}
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start",
                        "$opt_in", "$mobile_session_engagement", "$mobile_app_open"])
        XCTAssertEqual(events.filter { $0["event"] as? String == "$mobile_session_start" }.count, 1)
        XCTAssertEqual(events.filter { $0["event"] as? String == "$mobile_app_open" }.count, 2)
        let sid = (events.first?["defaultProperties"] as? [String: Any])?["sid"] as? String
        XCTAssertNotNil(sid)
        XCTAssertTrue(events.allSatisfy {
            ($0["defaultProperties"] as? [String: Any])?["sid"] as? String == sid
        })
    }

    func testCheckpointEngagementFollowsHeldOptIn() async {
        let (op, point) = await heldActiveOptIn()
        op.captureMobileTime = {
            MobileTimePoint(epochMs: point.epochMs + 10_000, monotonicMs: 10_000)
        }
        _ = op.mobileSession?.checkpoint(at: op.captureMobileTime())
        op.mobileForeground(at: MobileTimePoint(epochMs: point.epochMs + 10_000, monotonicMs: 10_000))
        op.trackingQueue.sync {}
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start",
                        "$opt_in", "$mobile_session_engagement"])
        XCTAssertEqual((events.last?["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int64,
                       10_000)
    }

    func testHeldIdentifyCompletionRunsOnDiscardWithoutPriorEvent() async {
        for reset in [false, true] {
            let (op, point) = await heldActiveOptIn(failingWrites: 20)
            let completed = expectation(description: "held identify discarded on \(reset ? "reset" : "opt-out")")
            op.identify(OursPrivacyUserProperties(externalId: "external-1")) {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            }
            op.trackingQueue.sync {}
            if reset { op.reset() } else { op.optOutTracking() }
            op.trackingQueue.sync {}
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

            let persist = OursPrivacyPersistence(instanceName: op.name).persistenceWrite
            op.oursprivacyPersistence.persistenceWrite = persist
            if !reset { op.optInTracking() }
            op.mobileForeground(at: MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: 1_000))
            op.trackingQueue.sync {}
            XCTAssertFalse(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
                .contains { $0["event"] as? String == "$identify" })
        }
    }

    func testIdentifyQueuedBehindOptOutStillCompletes() async {
        let op = makeMobileInstance()
        await op.initialize()
        let completed = expectation(description: "identify queued behind opt-out")
        op.trackingQueue.suspend()
        op.optOutTracking()
        op.identify(OursPrivacyUserProperties(externalId: "external-1")) {
            XCTAssertTrue(Thread.isMainThread)
            completed.fulfill()
        }
        op.trackingQueue.resume()
        op.trackingQueue.sync {}
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .contains { $0["event"] as? String == "$identify" })
    }

    func testIdentifyFailedPrivacyClearStillCompletes() async {
        let op = makeMobileInstance()
        await op.initialize()
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        XCTAssertFalse(op.oursprivacyPersistence.clearEntitiesForPrivacy())
        let completed = expectation(description: "identify after failed privacy clear")
        op.identify(OursPrivacyUserProperties(externalId: "external-1")) {
            XCTAssertTrue(Thread.isMainThread)
            completed.fulfill()
        }
        op.trackingQueue.sync {}
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .contains { $0["event"] as? String == "$identify" })
    }

    func testManualTrackWaitsForHeldActiveOptInWithoutAnotherCallback() async {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let foreground = MobileTimePoint(epochMs: 1_791_194_400_000, monotonicMs: 0)
        let manual = MobileTimePoint(epochMs: foreground.epochMs + 1_000, monotonicMs: 1_000)
        op.captureMobileTime = { foreground }
        op.mobileQueueNowMs = { foreground.epochMs + 5_000 }
        op.mobilePendingRetryIntervalMs = 60_000
        op.mobileForeground(at: foreground)
        op.trackingQueue.sync {}

        let persist = op.oursprivacyPersistence.persistenceWrite
        var failedWrites = 0
        op.oursprivacyPersistence.persistenceWrite = { data in
            if failedWrites < 3 {
                failedWrites += 1
                return false
            }
            return persist(data)
        }
        op.optInTracking()
        op.trackingQueue.sync {}
        op.captureMobileTime = { manual }
        op.track(event: "Blue", properties: ["shade": "cerulean"])
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(failedWrites, 3)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$opt_in", "Blue"])
        let sid = (events.first?["defaultProperties"] as? [String: Any])?["sid"] as? String
        XCTAssertNotNil(sid)
        XCTAssertTrue(events.allSatisfy {
            ($0["defaultProperties"] as? [String: Any])?["sid"] as? String == sid
        })
        XCTAssertTrue(events.allSatisfy { $0["visitor_id"] as? String == op.visitorId })
        let blue = events.first { $0["event"] as? String == "Blue" }
        XCTAssertEqual((blue?["eventProperties"] as? [String: Any])?["shade"] as? String, "cerulean")
        XCTAssertEqual((blue?["defaultProperties"] as? [String: Any])?["mobile_occurred_at"] as? String,
                       "2026-10-05T10:00:01.000Z")
    }

    func testHeldManualTrackRetriesWithoutDuplicatingOptInOrIdentify() async {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let point = MobileTimePoint(epochMs: 1_791_194_400_000, monotonicMs: 0)
        op.captureMobileTime = { point }
        op.mobileQueueNowMs = { point.epochMs + 5_000 }
        op.mobilePendingRetryIntervalMs = 60_000
        op.mobileForeground(at: point)
        op.trackingQueue.sync {}

        let persist = op.oursprivacyPersistence.persistenceWrite
        var failedWrites = 0
        var failedBlue = false
        op.oursprivacyPersistence.persistenceWrite = { data in
            if failedWrites < 3 {
                failedWrites += 1
                return false
            }
            let blob = JSONHandler.deserializeData(data) as? [String: Any]
            let names = (blob?["events"] as? [[String: Any]])?
                .compactMap { $0["event"] as? String } ?? []
            if names.last == "Blue" && !failedBlue {
                failedBlue = true
                return false
            }
            return persist(data)
        }
        op.optInTracking(userProperties: OursPrivacyUserProperties(externalId: "external-1"))
        op.trackingQueue.sync {}
        op.track(event: "Blue", properties: ["shade": "cerulean"])
        op.trackingQueue.sync {}

        let beforeRetry = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(failedWrites, 3)
        XCTAssertTrue(failedBlue)
        XCTAssertEqual(beforeRetry.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$identify", "$opt_in"])

        op.mobileForeground(at: MobileTimePoint(epochMs: point.epochMs + 2_000, monotonicMs: 2_000))
        op.trackingQueue.sync {}
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start",
                        "$identify", "$opt_in", "Blue"])
        XCTAssertEqual((events.last?["eventProperties"] as? [String: Any])?["shade"] as? String, "cerulean")
    }

    func testManualTrackRetriesWhenOpeningDrainSucceedsButItsWriteFails() async {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let point = MobileTimePoint(epochMs: 1_791_194_400_000, monotonicMs: 0)
        let manual = MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: 1_000)
        op.captureMobileTime = { point }
        op.mobileQueueNowMs = { point.epochMs + 5_000 }
        op.mobilePendingRetryIntervalMs = 60_000
        op.mobileForeground(at: point)
        op.trackingQueue.sync {}

        let persist = op.oursprivacyPersistence.persistenceWrite
        var failedOpeningWrites = 0
        var failedBlue = false
        op.oursprivacyPersistence.persistenceWrite = { data in
            if failedOpeningWrites < 2 {
                failedOpeningWrites += 1
                return false
            }
            let blob = JSONHandler.deserializeData(data) as? [String: Any]
            let names = (blob?["events"] as? [[String: Any]])?
                .compactMap { $0["event"] as? String } ?? []
            if names.last == "Blue" && !failedBlue {
                failedBlue = true
                return false
            }
            return persist(data)
        }
        op.optInTracking()
        op.trackingQueue.sync {}
        op.captureMobileTime = { manual }
        op.track(event: "Blue", properties: ["shade": "cerulean"])
        op.trackingQueue.sync {}

        let beforeRetry = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(failedOpeningWrites, 2)
        XCTAssertTrue(failedBlue)
        XCTAssertEqual(beforeRetry.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$opt_in"])

        op.mobileForeground(at: MobileTimePoint(epochMs: point.epochMs + 2_000, monotonicMs: 2_000))
        op.trackingQueue.sync {}
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$opt_in", "Blue"])
        XCTAssertEqual((events.last?["eventProperties"] as? [String: Any])?["shade"] as? String, "cerulean")
        XCTAssertEqual((events.last?["defaultProperties"] as? [String: Any])?["mobile_occurred_at"] as? String,
                       "2026-10-05T10:00:01.000Z")
    }

    func testIdentifyRetriesWhenOpeningDrainSucceedsButItsWriteFails() async {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let point = MobileTimePoint(epochMs: 1_791_194_400_000, monotonicMs: 0)
        op.captureMobileTime = { point }
        op.mobileQueueNowMs = { point.epochMs + 5_000 }
        op.mobilePendingRetryIntervalMs = 60_000
        op.mobileForeground(at: point)
        op.trackingQueue.sync {}

        let persist = op.oursprivacyPersistence.persistenceWrite
        var failedOpeningWrites = 0
        var failedIdentify = false
        op.oursprivacyPersistence.persistenceWrite = { data in
            if failedOpeningWrites < 2 {
                failedOpeningWrites += 1
                return false
            }
            let blob = JSONHandler.deserializeData(data) as? [String: Any]
            let names = (blob?["events"] as? [[String: Any]])?
                .compactMap { $0["event"] as? String } ?? []
            if names.last == "$identify" && !failedIdentify {
                failedIdentify = true
                return false
            }
            return persist(data)
        }
        op.optInTracking()
        op.trackingQueue.sync {}
        let completed = expectation(description: "identify persisted before completion")
        op.identify(OursPrivacyUserProperties(externalId: "external-1")) {
            completed.fulfill()
        }
        op.trackingQueue.sync {}

        let beforeRetry = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(failedOpeningWrites, 2)
        XCTAssertTrue(failedIdentify)
        XCTAssertEqual(beforeRetry.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$opt_in"])

        op.mobileForeground(at: MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: 1_000))
        op.trackingQueue.sync {}
        await fulfillment(of: [completed], timeout: 2)
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$opt_in", "$identify"])
        XCTAssertEqual((events.last?["userProperties"] as? [String: Any])?["external_id"] as? String, "external-1")
    }

    func testIdentifyAfterHeldOptInKeepsOrderAndCompletesAfterRetry() async {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let point = MobileTimePoint(epochMs: 1_791_194_400_000, monotonicMs: 0)
        op.captureMobileTime = { point }
        op.mobileQueueNowMs = { point.epochMs + 5_000 }
        op.mobilePendingRetryIntervalMs = 60_000
        op.mobileForeground(at: point)
        op.trackingQueue.sync {}

        let persist = op.oursprivacyPersistence.persistenceWrite
        var failedWrites = 0
        op.oursprivacyPersistence.persistenceWrite = { data in
            if failedWrites < 4 {
                failedWrites += 1
                return false
            }
            return persist(data)
        }
        op.optInTracking()
        op.trackingQueue.sync {}
        let completed = expectation(description: "identify queued after opt-in")
        op.identify(OursPrivacyUserProperties(externalId: "external-1")) {
            completed.fulfill()
        }
        op.trackingQueue.sync {}
        XCTAssertEqual(failedWrites, 4)
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        op.mobileForeground(at: MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: 1_000))
        op.trackingQueue.sync {}
        await fulfillment(of: [completed], timeout: 2)
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$opt_in", "$identify"])
        XCTAssertEqual(((events.last?["userProperties"] as? [String: Any])?["external_id"] as? String),
                       "external-1")
    }

    func testOptOutDiscardsManualEventHeldBehindOptIn() async {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let point = MobileTimePoint(epochMs: 1_791_194_400_000, monotonicMs: 0)
        op.captureMobileTime = { point }
        op.mobileQueueNowMs = { point.epochMs + 5_000 }
        op.mobilePendingRetryIntervalMs = 60_000
        op.mobileForeground(at: point)
        op.trackingQueue.sync {}
        let priorVisitorId = op.visitorId

        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.optInTracking()
        op.trackingQueue.sync {}
        op.track(event: "Blue")
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        op.optOutTracking()
        op.trackingQueue.sync {}
        XCTAssertNotEqual(op.visitorId, priorVisitorId)
        op.oursprivacyPersistence.persistenceWrite = persist
        op.optInTracking()
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$opt_in"])
        XCTAssertTrue(events.allSatisfy { $0["visitor_id"] as? String == op.visitorId })
    }

    func testResetDiscardsManualEventHeldBehindOptIn() async {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let point = MobileTimePoint(epochMs: 1_791_194_400_000, monotonicMs: 0)
        op.captureMobileTime = { point }
        op.mobileQueueNowMs = { point.epochMs + 5_000 }
        op.mobilePendingRetryIntervalMs = 60_000
        op.mobileForeground(at: point)
        op.trackingQueue.sync {}
        let priorVisitorId = op.visitorId

        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.optInTracking()
        op.trackingQueue.sync {}
        op.track(event: "Blue")
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        op.reset()
        op.trackingQueue.sync {}
        XCTAssertNotEqual(op.visitorId, priorVisitorId)
        op.oursprivacyPersistence.persistenceWrite = persist
        op.track(event: "Green")
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String }, ["Green"])
        XCTAssertEqual(events.first?["visitor_id"] as? String, op.visitorId)
    }

    func testActiveOptInQueuesDueOpenBeforeOptInAfterTwoFailedWrites() async {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let point = mobilePoint()
        op.captureMobileTime = { point }
        op.mobileQueueNowMs = { point.epochMs + 1_000 }
        op.mobilePendingRetryIntervalMs = 60_000
        op.mobileForeground(at: point)
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        let persist = op.oursprivacyPersistence.persistenceWrite
        var failedWrites = 0
        op.oursprivacyPersistence.persistenceWrite = { data in
            if failedWrites < 2 {
                failedWrites += 1
                return false
            }
            return persist(data)
        }
        op.optInTracking(properties: ["source": "settings"])
        op.trackingQueue.sync {}
        XCTAssertEqual(failedWrites, 2)
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        let retry = MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: point.monotonicMs + 1_000)
        op.mobileForeground(at: retry)
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$opt_in"])
        let sid = (events.first?["defaultProperties"] as? [String: Any])?["sid"] as? String
        XCTAssertNotNil(sid)
        XCTAssertTrue(events.allSatisfy {
            ($0["defaultProperties"] as? [String: Any])?["sid"] as? String == sid
        })
        XCTAssertTrue(events.allSatisfy { $0["visitor_id"] as? String == op.visitorId })
        XCTAssertEqual((events.last?["eventProperties"] as? [String: Any])?["source"] as? String, "settings")
        XCTAssertTrue(op.mobileSession?.hasAcceptedFirstOpen ?? false)
    }

    func testActiveOptInRetriesFailedEventWriteWithoutDuplicatingIdentify() async {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let point = mobilePoint()
        op.captureMobileTime = { point }
        op.mobileQueueNowMs = { point.epochMs + 1_000 }
        op.mobilePendingRetryIntervalMs = 60_000
        op.mobileForeground(at: point)
        op.trackingQueue.sync {}

        let persist = op.oursprivacyPersistence.persistenceWrite
        var failedOptIn = false
        op.oursprivacyPersistence.persistenceWrite = { data in
            let blob = JSONHandler.deserializeData(data) as? [String: Any]
            let names = (blob?["events"] as? [[String: Any]])?
                .compactMap { $0["event"] as? String } ?? []
            if names.last == "$opt_in" && !failedOptIn {
                failedOptIn = true
                return false
            }
            return persist(data)
        }
        op.optInTracking(userProperties: OursPrivacyUserProperties(externalId: "external-1"),
                         properties: ["source": "settings"])
        op.trackingQueue.sync {}
        op.trackingQueue.sync {}

        let beforeRetry = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertTrue(failedOptIn)
        XCTAssertEqual(beforeRetry.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$identify"])

        op.oursprivacyPersistence.persistenceWrite = persist
        op.mobileForeground(at: MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: point.monotonicMs + 1_000))
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$identify", "$opt_in"])
        XCTAssertEqual(((events[3]["userProperties"] as? [String: Any])?["external_id"] as? String),
                       "external-1")
        XCTAssertEqual((events.last?["eventProperties"] as? [String: Any])?["source"] as? String, "settings")
    }

    func testActiveOptInRetriesOnTimerAfterStorageRecovers() async {
        let op = makeMobileInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        let point = mobilePoint()
        op.captureMobileTime = { point }
        op.mobileQueueNowMs = { point.epochMs + 1_000 }
        op.mobilePendingRetryIntervalMs = 25
        op.mobileForeground(at: point)
        op.trackingQueue.sync {}

        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { data in
            let blob = JSONHandler.deserializeData(data) as? [String: Any]
            let names = (blob?["events"] as? [[String: Any]])?
                .compactMap { $0["event"] as? String } ?? []
            return names.last == "$opt_in" ? false : persist(data)
        }
        op.optInTracking()
        op.trackingQueue.sync {}
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start"])

        op.trackingQueue.sync {
            op.oursprivacyPersistence.persistenceWrite = persist
        }
        for _ in 0 ..< 50 {
            if op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count == 4 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$opt_in"])
    }

    func testActiveCallbackRetriesForegroundAfterPrivacyClearRecovers() async {
        let op = makeMobileInstance()
        await op.initialize()
        let point = mobilePoint()
        op.mobileQueueNowMs = { point.epochMs + 2_000 }
        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        XCTAssertFalse(op.oursprivacyPersistence.clearEntitiesForPrivacy())
        XCTAssertTrue(op.oursprivacyPersistence.hasPendingPrivacyClear)

        op.mobileForeground(at: point)
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        XCTAssertTrue(op.mobileSession?.pendingFacts.isEmpty ?? false)

        op.oursprivacyPersistence.persistenceWrite = persist
        let retry = MobileTimePoint(epochMs: point.epochMs + 1_000, monotonicMs: point.monotonicMs + 1_000)
        op.mobileForeground(at: retry)
        op.mobileForeground(at: retry)
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertFalse(op.oursprivacyPersistence.hasPendingPrivacyClear)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start"])
        XCTAssertEqual((events.first?["defaultProperties"] as? [String: Any])?["mobile_occurred_at"] as? String,
                       (events.last?["defaultProperties"] as? [String: Any])?["mobile_occurred_at"] as? String)
    }

    func assertResumedTimerCheckpointsCumulativeEngagement(recreate: Bool, inactiveOnly: Bool = false) async {
        let name = "resumed-checkpoint-\(UUID().uuidString)"
        let makeInstance = { () -> OursPrivacy in
            let instance = OursPrivacy(token: name, trackAutomaticEvents: true)
            instance.mobileSession = MobileSession(instanceName: name)
            instance.mobileRuntimeEnabled = true
            instance.flushInstance.delegate = nil
            instance.flushInstance._flushInterval = 0
            return instance
        }
        let original = makeInstance()
        await original.initialize()
        let start = MobileTimePoint(epochMs: Int64(Date().timeIntervalSince1970 * 1_000), monotonicMs: 0)
        original.mobileQueueNowMs = { start.epochMs + 20_000 }
        original.mobileForeground(at: start)
        let paused = MobileTimePoint(epochMs: start.epochMs + 9_000, monotonicMs: 9_000)
        if inactiveOnly {
            original.mobilePause(at: paused)
        } else {
            original.mobileBackground(at: paused)
        }
        original.trackingQueue.sync {}
        let initialEngagement = original.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .filter { $0["event"] as? String == "$mobile_session_engagement" }
        let initialProperties = initialEngagement.first?["eventProperties"] as? [String: Any]
        XCTAssertEqual(initialProperties?["engagement_duration_ms"] as? Int64, 9_000)

        let resumed: OursPrivacy
        if recreate {
            let restored = makeInstance()
            restored.mobileQueueNowMs = { start.epochMs + 20_000 }
            await restored.initialize()
            resumed = restored
        } else {
            resumed = original
        }

        let timerFired = expectation(description: "checkpoint after remaining foreground second")
        resumed.captureMobileTime = {
            timerFired.fulfill()
            return MobileTimePoint(epochMs: start.epochMs + 11_000, monotonicMs: 11_000)
        }
        resumed.mobileForeground(at: MobileTimePoint(epochMs: start.epochMs + 10_000, monotonicMs: 10_000))
        resumed.trackingQueue.sync {}
        await fulfillment(of: [timerFired], timeout: 5)
        resumed.trackingQueue.sync {}

        let beforeBackground = resumed.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .filter { $0["event"] as? String == "$mobile_session_engagement" }
        let durations = beforeBackground.compactMap {
            ($0["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int64
        }
        XCTAssertEqual(durations, [9_000, 1_000])
        let firstSid = (beforeBackground.first?["defaultProperties"] as? [String: Any])?["sid"] as? String
        XCTAssertNotNil(firstSid)
        XCTAssertEqual(firstSid, (beforeBackground.last?["defaultProperties"] as? [String: Any])?["sid"] as? String)
        XCTAssertNotEqual(beforeBackground.first?["distinct_id"] as? String,
                          beforeBackground.last?["distinct_id"] as? String)

        resumed.mobileBackground(at: MobileTimePoint(epochMs: start.epochMs + 11_000, monotonicMs: 11_000))
        resumed.trackingQueue.sync {}
        let afterBackground = resumed.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .filter { $0["event"] as? String == "$mobile_session_engagement" }
        XCTAssertEqual(afterBackground.count, 2)
    }
}
