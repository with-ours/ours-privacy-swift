import XCTest
@testable import OursPrivacyKit

final class TrackConsentTests: XCTestCase {
    func testUserPropertiesMergeOmitsExplicitEmptyConsentWithoutDefaults() {
        let onlyEmptyConsent = Track.mergeUserProperties(
            perCall: ["consent": [:]], defaultCustom: [:], defaultConsent: [:])
        XCTAssertNil(onlyEmptyConsent)

        let withEmail = Track.mergeUserProperties(
            perCall: ["email": "u@example.com", "consent": [:]],
            defaultCustom: [:], defaultConsent: [:])
        XCTAssertEqual(withEmail?["email"] as? String, "u@example.com")
        XCTAssertNil(withEmail?["consent"])
    }

    func testUserPropertiesMergeFastPathPassesPerCallThrough() {
        // No store-level defaults configured ⇒ per-call returned unchanged.
        let merged = Track.mergeUserProperties(
            perCall: ["email": "u@example.com", "consent": ["analytics": true]],
            defaultCustom: [:],
            defaultConsent: [:])
        XCTAssertEqual(merged?["email"] as? String, "u@example.com")
        let consent = merged?["consent"] as? [String: Any]
        XCTAssertEqual(consent?["analytics"] as? Bool, true)
    }

}
