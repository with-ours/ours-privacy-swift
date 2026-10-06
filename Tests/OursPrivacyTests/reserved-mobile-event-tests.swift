import XCTest
@testable import OursPrivacyKit

final class ReservedMobileEventTests: XCTestCase {
    func testComposerRejectsEveryCallerMobileNameBeforeMergingProperties() {
        let context = EventContext(visitorId: "visitor",
                                   defaultEventProperties: ["private_marker": "patient-field"],
                                   userCustomProperties: ["private_marker": "patient-field"],
                                   userConsentProperties: [:],
                                   attributionDefaultProperties: [:])
        for name in ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start",
                     "$mobile_session_engagement", "$mobile_session_end", "$mobile_app_update",
                     "$mobile_screen_view", "$mobile_custom"] {
            let item = Track().composeTrackEvent(event: name,
                                                 eventProperties: ["private_marker": "patient-field"],
                                                 userProperties: ["email": "private@example.test"],
                                                 context: context)
            XCTAssertTrue(item.isEmpty, name)
        }
    }

    func testTypedAndUntypedManualTrackingCannotQueueMobileFacts() async {
        let token = "reserved-\(UUID().uuidString)"
        let op = OursPrivacy(token: token, trackAutomaticEvents: false)
        op.mobileSession = MobileSession(instanceName: token)
        op.mobileRuntimeEnabled = true
        await op.initialize(options: OursPrivacyInitOptions(
            defaultEventProperties: ["private_marker": "patient-field"],
            defaultUserCustomProperties: ["private_marker": "patient-field"]))

        op.track(event: "$mobile_first_open",
                 properties: ["private_marker": "patient-field"],
                 userProperties: OursPrivacyUserProperties(email: "private@example.test"))
        op.trackUntyped(event: "$mobile_session_engagement",
                        properties: ["engagement_duration_ms": 10_000, "private_marker": "patient-field"],
                        userProperties: ["email": "private@example.test"])
        op.track(event: "$mobile_custom")
        op.trackingQueue.sync {}

        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    func testGenuineFirstOpenKeepsCallerPropertiesOutOfCanonicalFacts() async {
        let token = "genuine-\(UUID().uuidString)"
        let op = OursPrivacy(token: token, trackAutomaticEvents: true)
        op.mobileSession = MobileSession(instanceName: token)
        op.mobileRuntimeEnabled = true
        await op.initialize(options: OursPrivacyInitOptions(
            defaultEventProperties: ["private_marker": "patient-field"],
            defaultUserCustomProperties: ["private_marker": "patient-field"]))
        op.mobileForeground(at: MobileTimePoint.capture())
        op.trackingQueue.sync {}

        let facts = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .filter { ($0["event"] as? String)?.hasPrefix("$mobile_") == true }
        XCTAssertEqual(facts.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start"])
        for fact in facts {
            XCTAssertTrue(fact["eventProperties"] is NSNull)
            XCTAssertTrue(fact["userProperties"] is NSNull)
            XCTAssertNil((fact["defaultProperties"] as? [String: Any])?["private_marker"])
        }
    }
}
