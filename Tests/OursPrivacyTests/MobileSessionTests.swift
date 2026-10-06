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
