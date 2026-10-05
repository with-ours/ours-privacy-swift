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
}
