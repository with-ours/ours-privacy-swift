import XCTest
@testable import OursPrivacyKit

final class OursPrivacyTests: XCTestCase {

    // MARK: - Endpoint / route invariants

    func testMaxBatchSizeIsClampedAt50() {
        XCTAssertEqual(APIConstants.maxBatchSize, 50)
    }

    func testDefaultAPIEndpointIsCdn() {
        XCTAssertEqual(BasePath.DefaultAPIEndpoint, "https://cdn.oursprivacy.com")
    }

    func testAllFlushesGoToIngest() {
        for type in [FlushType.events] {
            XCTAssertEqual(type.rawValue, "/ingest", "\(type) must POST to /ingest")
        }
    }

    func testEventsRequestURLComposesToCdnIngest() {
        let url = BasePath.buildURL(base: BasePath.DefaultAPIEndpoint,
                                    path: FlushType.events.rawValue,
                                    queryItems: nil)
        XCTAssertEqual(url?.absoluteString, "https://cdn.oursprivacy.com/ingest")
    }

    // MARK: - composeTrackEvent: canonical shape

    private func makeContext(visitorId: String = "test-visitor",
                             defaultEventProperties: [String: Any] = [:],
                             userCustomProperties: [String: Any] = [:],
                             userConsentProperties: [String: Any] = [:],
                             attributionDefaultProperties: [String: Any] = [:]) -> EventContext {
        EventContext(visitorId: visitorId,
                     defaultEventProperties: defaultEventProperties,
                     userCustomProperties: userCustomProperties,
                     userConsentProperties: userConsentProperties,
                     attributionDefaultProperties: attributionDefaultProperties)
    }

    func testComposeTrackEventCanonicalShape() {
        let track = Track()
        let item = track.composeTrackEvent(event: "Purchase",
                                           eventProperties: ["sku": "A"],
                                           userProperties: nil,
                                           context: makeContext())
        // Top-level keys match the server's `eventSchema` in
        // martech/packages/types/src/event.ts.
        XCTAssertEqual(Set(item.keys),
                       Set(["event", "visitor_id", "distinct_id",
                            "eventProperties", "userProperties", "defaultProperties"]))
        XCTAssertEqual(item["event"] as? String, "Purchase")
        XCTAssertEqual(item["visitor_id"] as? String, "test-visitor")
        XCTAssertNotNil(item["distinct_id"] as? String)
        XCTAssertEqual((item["eventProperties"] as? [String: Any])?["sku"] as? String, "A")
        XCTAssertTrue(item["userProperties"] is NSNull)
        XCTAssertNotNil(item["defaultProperties"] as? [String: Any])
    }

    func testComposeTrackEventHasNoLegacyKeys() {
        let track = Track()
        let item = track.composeTrackEvent(event: "Some Event",
                                           eventProperties: ["k": "v"],
                                           userProperties: nil,
                                           context: makeContext())
        // Legacy Mixpanel keys must not appear at any level of the payload.
        let legacy = ["mp_lib", "$lib_version", "$mp_metadata", "$os", "$model",
                      "$device_id", "$user_id", "$had_persisted_distinct_id",
                      "userId", "token", "$duration"]
        for key in legacy {
            XCTAssertNil(item[key], "legacy key '\(key)' must not be present on the event item")
        }
        if let ep = item["eventProperties"] as? [String: Any] {
            for key in legacy {
                XCTAssertNil(ep[key], "legacy key '\(key)' must not be present under eventProperties")
            }
        }
        if let dp = item["defaultProperties"] as? [String: Any] {
            for key in legacy {
                XCTAssertNil(dp[key], "legacy key '\(key)' must not be present under defaultProperties")
            }
        }
    }

    func testComposeTrackEventSpreadsDefaultEventProperties() {
        let track = Track()
        let item = track.composeTrackEvent(
            event: "View",
            eventProperties: ["page": "home"],
            userProperties: nil,
            context: makeContext(defaultEventProperties: ["release": "1.0", "page": "stale"]))
        let ep = item["eventProperties"] as? [String: Any]
        XCTAssertEqual(ep?["release"] as? String, "1.0")
        // Per-call wins on key collision — matches format-track.ts:54-57.
        XCTAssertEqual(ep?["page"] as? String, "home")
    }

    func testComposeTrackEventHonorsDistinctIdOverride() {
        let track = Track()
        let item = track.composeTrackEvent(
            event: "View",
            eventProperties: ["$distinct_id": "explicit-cuid"],
            userProperties: nil,
            context: makeContext())
        XCTAssertEqual(item["distinct_id"] as? String, "explicit-cuid")
        // The magic key must not leak into the wire eventProperties.
        XCTAssertNil((item["eventProperties"] as? [String: Any])?["$distinct_id"])
    }

    // MARK: - composeIdentifyEvent

    func testComposeIdentifyEventCanonicalShape() {
        let track = Track()
        let item = track.composeIdentifyEvent(
            distinctId: "user-123",
            userProperties: ["email": "u@example.com", "first_name": "U"],
            context: makeContext())
        XCTAssertEqual(item["event"] as? String, "$identify")
        XCTAssertTrue(item["eventProperties"] is NSNull)
        let up = item["userProperties"] as? [String: Any]
        XCTAssertEqual(up?["external_id"] as? String, "user-123")
        XCTAssertEqual(up?["email"] as? String, "u@example.com")
        XCTAssertEqual(up?["first_name"] as? String, "U")
    }

    // MARK: - userProperties merge (web-cdp parity)

    func testUserPropertiesMergeSpreadsCustomDefaultsUnderPerCall() {
        // defaults: { plan: 'pro' }; per-call: { tier: 'gold' } ⇒ merged
        // custom_properties: { plan: 'pro', tier: 'gold' }. Per-call wins
        // on key collision.
        let merged = Track.mergeUserProperties(
            perCall: ["custom_properties": ["tier": "gold", "plan": "lite"]],
            defaultCustom: ["plan": "pro", "region": "us"],
            defaultConsent: [:])
        let custom = merged?["custom_properties"] as? [String: Any]
        XCTAssertEqual(custom?["region"] as? String, "us")
        XCTAssertEqual(custom?["plan"] as? String, "lite")     // per-call wins
        XCTAssertEqual(custom?["tier"] as? String, "gold")
    }

    func testUserPropertiesMergeOmitsConsentWhenBothSidesEmpty_OUR3669() {
        // OUR-3669: if neither default-consent nor per-call consent has data,
        // the `consent` key must be omitted entirely — emitting `consent: {}`
        // races with the CMP's $consent_init and overwrites real consent data.
        let merged = Track.mergeUserProperties(
            perCall: ["email": "u@example.com"],
            defaultCustom: ["plan": "pro"],
            defaultConsent: [:])
        XCTAssertNil(merged?["consent"], "consent key must be omitted when both sides empty (OUR-3669)")
        XCTAssertEqual(merged?["email"] as? String, "u@example.com")
    }

    func testUserPropertiesMergeIncludesConsentWhenEitherSideHasData() {
        let mergedDefaults = Track.mergeUserProperties(
            perCall: nil,
            defaultCustom: [:],
            defaultConsent: ["analytics": true])
        XCTAssertNotNil(mergedDefaults?["consent"])

        let mergedPerCall = Track.mergeUserProperties(
            perCall: ["consent": ["marketing": true]],
            defaultCustom: [:],
            defaultConsent: [:])
        XCTAssertNotNil(mergedPerCall?["consent"])
    }

    func testUserPropertiesMergeReturnsNilWhenNothing() {
        let merged = Track.mergeUserProperties(
            perCall: nil, defaultCustom: [:], defaultConsent: [:])
        XCTAssertNil(merged)
    }

    func testUserPropertiesMergeFastPathPassesPerCallThrough() {
        // No store-level defaults configured ⇒ per-call returned unchanged.
        let merged = Track.mergeUserProperties(
            perCall: ["email": "u@example.com", "consent": ["analytics": true]],
            defaultCustom: [:],
            defaultConsent: [:])
        XCTAssertEqual(merged?["email"] as? String, "u@example.com")
        XCTAssertNotNil(merged?["consent"])
    }

    // MARK: - defaultProperties canonical keys

    func testDefaultPropertiesUsesCanonicalKeys() {
        let p = AutomaticProperties.defaultProperties
        XCTAssertNotNil(p["device_vendor"])
        XCTAssertNotNil(p["device_model"])
        XCTAssertNotNil(p["version"])
        // device_type / os_name / os_version / screen_* depend on the host
        // platform; at minimum the cross-platform anchors must be present.
        // Legacy Mixpanel keys must be absent.
        for legacy in ["$os", "$os_version", "$model", "$manufacturer", "mp_lib",
                       "$lib_version", "$screen_width", "$screen_height",
                       "$app_version_string", "$app_build_number"] {
            XCTAssertNil(p[legacy], "legacy key '\(legacy)' must not appear in defaultProperties")
        }
    }
}
