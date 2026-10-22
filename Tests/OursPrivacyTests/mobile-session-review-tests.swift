import Foundation
import XCTest
@testable import OursPrivacyKit

final class MobileSessionReviewTests: XCTestCase {
    private let origin: Int64 = 1_791_194_400_000
    private var names: [String] = []

    override func tearDown() {
        let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)
        for name in names {
            defaults?.removeObject(forKey: "oursprivacy-\(name)-OPMobileSession")
        }
        super.tearDown()
    }

    private func makeSession(_ name: String? = nil) -> MobileSession {
        let instanceName = name ?? "mobile-review-\(UUID().uuidString)"
        names.append(instanceName)
        return MobileSession(instanceName: instanceName)
    }

    private func point(_ elapsedMs: Int64) -> MobileTimePoint {
        MobileTimePoint(epochMs: origin + elapsedMs, monotonicMs: elapsedMs)
    }

    func testSameMillisecondIdentityRotationsUseDistinctPersistedSessionIds() throws {
        let name = "same-millisecond-\(UUID().uuidString)"
        let session = makeSession(name)
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        let original = try XCTUnwrap(opened.first?.sid)
        let first = session.rotate(to: "visitor-b", appVersion: nil, appBuild: nil, at: point(0))
        let second = session.rotate(to: "visitor-c", appVersion: nil, appBuild: nil, at: point(0))
        let firstStart = try XCTUnwrap(first.first { $0.name == "$mobile_session_start" })
        let secondStart = try XCTUnwrap(second.first { $0.name == "$mobile_session_start" })

        XCTAssertEqual(first.map(\.name), ["$mobile_session_end", "$mobile_session_start"])
        XCTAssertEqual(second.map(\.name), ["$mobile_session_end", "$mobile_session_start"])
        XCTAssertEqual(first.first?.sid, original)
        XCTAssertEqual(second.first?.sid, firstStart.sid)
        XCTAssertEqual(Set([original, firstStart.sid, secondStart.sid]).count, 3)
        XCTAssertEqual(firstStart.sid, String(origin + 1))
        XCTAssertEqual(secondStart.sid, String(origin + 2))

        let restored = makeSession(name)
        let snapshot = restored.snapshot(visitorId: "visitor-c", at: point(0))
        XCTAssertEqual(snapshot.sid, secondStart.sid)
        XCTAssertEqual(snapshot.startedAtMs, secondStart.startedAtMs)
        _ = restored.foreground(automaticEnabled: true, visitorId: "visitor-c", at: point(0))
        let third = restored.rotate(to: "visitor-d", appVersion: nil, appBuild: nil, at: point(1))
        XCTAssertEqual(third.last?.sid, String(origin + 3))
    }

    func testUpgradeWithPersistedIdentitySuppressesFirstOpenWithoutAutomaticEvents() {
        let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)
        for identityKey in [OursPrivacyUserDefaultsKeys.visitorId, OursPrivacyUserDefaultsKeys.legacyDistinctID] {
            let name = "identity-upgrade-\(UUID().uuidString)"
            let key = "\(OursPrivacyUserDefaultsKeys.prefix)-\(name)-\(identityKey)"
            defaults?.set("existing-visitor", forKey: key)
            defer { defaults?.removeObject(forKey: key) }
            let session = makeSession(name)
            let facts = session.foreground(automaticEnabled: true, visitorId: "existing-visitor",
                                           appVersion: "3.1", at: point(0))

            XCTAssertTrue(session.hasAcceptedFirstOpen, identityKey)
            XCTAssertEqual(facts.map(\.name), ["$mobile_app_open", "$mobile_session_start"], identityKey)
            let restored = makeSession(name)
            XCTAssertTrue(restored.hasAcceptedFirstOpen, identityKey)
        }
        let fresh = makeSession()
        XCTAssertEqual(fresh.foreground(automaticEnabled: true, visitorId: "fresh-visitor", at: point(0))
            .first?.name, "$mobile_first_open")
    }

    func testIdentityRotationsDuringSmallClockRollbackDoNotReuseSessionIds() throws {
        let session = makeSession()
        let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
        let backward = MobileTimePoint(epochMs: origin - 1, monotonicMs: 1)
        let first = session.rotate(to: "visitor-b", appVersion: nil, appBuild: nil, at: backward)
        let recovered = MobileTimePoint(epochMs: origin, monotonicMs: 2)
        let second = session.rotate(to: "visitor-c", appVersion: nil, appBuild: nil, at: recovered)
        let firstStart = try XCTUnwrap(first.last)
        let secondStart = try XCTUnwrap(second.last)

        XCTAssertEqual(firstStart.sid, String(origin + 1))
        XCTAssertEqual(secondStart.sid, String(origin + 2))
        XCTAssertEqual(Set([opened[0].sid, firstStart.sid, secondStart.sid]).count, 3)
    }

    func testForegroundRollbackReplacesStartedSessionAndKeepsMeasuringEngagement() throws {
        for trigger in ["checkpoint", "pause", "resume", "screen", "snapshot"] {
            let session = makeSession()
            let opened = session.foreground(automaticEnabled: true, visitorId: "visitor-a", at: point(0))
            _ = session.screen("Schedule", visitorId: "visitor-a", at: point(0))
            if trigger == "resume" { _ = session.pauseActive(at: point(9_000)) }
            session.acknowledgeQueuedFacts(Set(session.pendingFacts.map(\.distinctId)), firstOpenQueueEvidence: true)
            let rollback = MobileTimePoint(epochMs: origin - 300_001, monotonicMs: 10_000)
            var resumed = rollback
            switch trigger {
            case "checkpoint":
                _ = session.checkpoint(at: rollback)
            case "pause":
                _ = session.pauseActive(at: rollback)
                resumed = MobileTimePoint(epochMs: rollback.epochMs + 1_000, monotonicMs: 11_000)
                XCTAssertTrue(session.resumeActive(at: resumed))
            case "resume":
                XCTAssertTrue(session.resumeActive(at: rollback))
            case "screen":
                _ = session.screen("Booking", visitorId: "visitor-a", at: rollback)
            default:
                _ = session.snapshot(visitorId: "visitor-a", at: rollback)
            }
            let end = try XCTUnwrap(session.pendingFacts.first { $0.name == "$mobile_session_end" }, trigger)
            let start = try XCTUnwrap(session.pendingFacts.first { $0.name == "$mobile_session_start" }, trigger)
            XCTAssertEqual(end.sid, opened[0].sid, trigger)
            XCTAssertNotEqual(start.sid, end.sid, trigger)
            XCTAssertEqual(start.occurredAtMs, rollback.epochMs, trigger)
            XCTAssertFalse(session.pendingFacts.contains { $0.name == "$mobile_app_open" }, trigger)

            let later = MobileTimePoint(epochMs: resumed.epochMs + 10_000, monotonicMs: resumed.monotonicMs + 10_000)
            let engagement = try XCTUnwrap(session.checkpoint(at: later).first, trigger)
            XCTAssertEqual(engagement.name, "$mobile_session_engagement", trigger)
            XCTAssertEqual(engagement.sid, start.sid, trigger)
            XCTAssertEqual(engagement.properties["engagement_duration_ms"] as? Int64, 10_000, trigger)
            XCTAssertEqual(engagement.properties["screen_name"] as? String,
                           trigger == "screen" ? "Booking" : "Schedule", trigger)
        }
    }
}
