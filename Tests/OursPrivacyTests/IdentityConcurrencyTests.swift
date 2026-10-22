import Foundation
import XCTest
@testable import OursPrivacyKit

final class IdentityConcurrencyTests: XCTestCase {
    func testPublicIdentityReadsDuringConcurrentUpdates() {
        let op = OursPrivacy(token: "identity-concurrency-\(UUID().uuidString)", trackAutomaticEvents: false)
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            for iteration in 0 ..< 500 {
                if index == 0 {
                    op.setVisitorId("visitor-\(iteration)")
                } else {
                    XCTAssertFalse(op.visitorId.isEmpty)
                    _ = op.isManuallySetId
                    XCTAssertNotNil(op.getVisitorId())
                    _ = op.debugDescription
                }
            }
        }
        op.trackingQueue.sync {}
        XCTAssertEqual(op.visitorId, "visitor-499")
        XCTAssertTrue(op.isManuallySetId)
    }

    func testVisitorSetterReturnsBeforeTrackingBacklogAndPreservesEventIdentityOrder() {
        let op = OursPrivacy(token: "identity-order-\(UUID().uuidString)", trackAutomaticEvents: false)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
        let originalVisitor = op.visitorId
        let returned = DispatchSemaphore(value: 0)
        op.trackingQueue.suspend()
        op.track(event: "before")
        DispatchQueue.global().async {
            op.setVisitorId("linked-visitor")
            op.track(event: "after")
            returned.signal()
        }
        let result = returned.wait(timeout: .now() + 2)
        XCTAssertEqual(op.getVisitorId(), "linked-visitor")
        XCTAssertTrue(op.isManuallySetId)
        op.trackingQueue.resume()
        XCTAssertEqual(result, .success)
        if result != .success {
            XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
        }
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String }, ["before", "after"])
        XCTAssertEqual(events.compactMap { $0["visitor_id"] as? String }, [originalVisitor, "linked-visitor"])
        XCTAssertEqual(events.compactMap { $0[OursPrivacyPersistence.localIdentityModeKey] as? Bool }, [false, true])
    }

    func testVisitorRotationKeepsForegroundClockContinuousWithoutAppOpen() async {
        let name = "identity-mobile-\(UUID().uuidString)"
        let session = MobileSession(instanceName: name)
        let op = OursPrivacy(token: name, trackAutomaticEvents: true)
        op.flushInstance.delegate = nil
        op.mobileRuntimeEnabled = true
        op.mobileSession = session
        await op.initialize()
        let origin = Int64(Date().timeIntervalSince1970 * 1_000)
        op.mobileForeground(at: MobileTimePoint(epochMs: origin, monotonicMs: 0))
        op.trackingQueue.sync {}
        let before = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let firstSid = (before.first?["defaultProperties"] as? [String: Any])?["sid"] as? String

        let captured = DispatchSemaphore(value: 0)
        let rotated = DispatchSemaphore(value: 0)
        op.captureMobileTime = {
            captured.signal()
            return MobileTimePoint(epochMs: origin + 10_000, monotonicMs: 10_000)
        }
        op.trackingQueue.suspend()
        DispatchQueue.global().async {
            op.setVisitorId("after-rotation")
            rotated.signal()
        }
        XCTAssertEqual(captured.wait(timeout: .now() + 2), .success)
        op.trackingQueue.resume()
        XCTAssertEqual(rotated.wait(timeout: .now() + 2), .success)
        op.mobileQueueNowMs = { origin + 70_000 }
        op.mobileBackground(at: MobileTimePoint(epochMs: origin + 70_000, monotonicMs: 70_000))
        op.trackingQueue.sync {}
        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let engagements = items.filter { $0["event"] as? String == "$mobile_session_engagement" }
        XCTAssertEqual(engagements.count, 2)
        let durations = engagements.compactMap {
            ($0["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int64
        }
        XCTAssertEqual(durations, [10_000, 60_000])
        let lastSid = (engagements.last?["defaultProperties"] as? [String: Any])?["sid"] as? String
        XCTAssertNotEqual(lastSid, firstSid)
        XCTAssertEqual(items.filter { $0["event"] as? String == "$mobile_app_open" }.count, 1)
    }
}
