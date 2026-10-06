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
        XCTAssertEqual(op.visitorId, "visitor-499")
        XCTAssertTrue(op.isManuallySetId)
    }

    func testVisitorRotationKeepsForegroundClockContinuousWithoutAppOpen() async {
        let name = "identity-mobile-\(UUID().uuidString)"
        let op = OursPrivacy(token: name, trackAutomaticEvents: true)
        op.mobileRuntimeEnabled = true
        op.mobileSession = MobileSession(instanceName: name)
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
