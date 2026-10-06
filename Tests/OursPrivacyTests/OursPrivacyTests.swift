import XCTest
@testable import OursPrivacyKit

private final class RecordingFlushRequest: FlushRequest, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []

    override func sendRequest(_ requestData: String, type: FlushType,
                              headers: [String: String], queryItems: [URLQueryItem] = []) -> Bool {
        lock.lock()
        bodies.append(requestData)
        lock.unlock()
        return true
    }

    var sentBodies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }
}

private final class HeldFirstFlushRequest: FlushRequest, @unchecked Sendable {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var bodies: [String] = []

    override func sendRequest(_ requestData: String, type: FlushType,
                              headers: [String: String], queryItems: [URLQueryItem] = []) -> Bool {
        lock.lock()
        bodies.append(requestData)
        let isFirst = bodies.count == 1
        lock.unlock()
        if isFirst {
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 5)
        }
        return true
    }

    var sentBodies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }
}

private final class LockedMobileClock: @unchecked Sendable {
    private let lock = NSLock()
    private var epochMs: Int64

    init(_ epochMs: Int64) {
        self.epochMs = epochMs
    }

    func now() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return epochMs
    }

    func set(_ value: Int64) {
        lock.lock()
        epochMs = value
        lock.unlock()
    }
}

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
        // Legacy snake_case / dollar-prefixed keys must not appear at any level
        // of the typed payload.
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
            userProperties: ["external_id": "user-123",
                             "email": "u@example.com",
                             "first_name": "U"],
            context: makeContext())
        XCTAssertEqual(item["event"] as? String, "$identify")
        XCTAssertTrue(item["eventProperties"] is NSNull)
        let up = item["userProperties"] as? [String: Any]
        XCTAssertEqual(up?["external_id"] as? String, "user-123")
        XCTAssertEqual(up?["email"] as? String, "u@example.com")
        XCTAssertEqual(up?["first_name"] as? String, "U")
    }

    func testIdentifyAcceptsNoArgs() {
        // No external id required; calling identify() with nothing fires
        // an empty $identify event.
        let op = makeInstance()
        op.identify()
        op.trackingQueue.sync {}
        let pending = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0]["event"] as? String, "$identify")
        // No external_id should be present when the caller didn't supply one.
        if let up = pending[0]["userProperties"] as? [String: Any] {
            XCTAssertNil(up["external_id"])
        }
    }

    func testIdentifySetsExternalIdFromStructField() {
        let op = makeInstance()
        op.identify(OursPrivacyUserProperties(email: "u@example.com",
                                              externalId: "user-123"))
        op.trackingQueue.sync {}
        let pending = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(pending.count, 1)
        let up = pending[0]["userProperties"] as? [String: Any]
        XCTAssertEqual(up?["external_id"] as? String, "user-123")
        XCTAssertEqual(up?["email"] as? String, "u@example.com")
    }

    // MARK: - userProperties merge

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

    func testUserPropertiesMergeOmitsConsentWhenBothSidesEmpty() {
        // If neither default-consent nor per-call consent has data, the
        // `consent` key must be omitted entirely — emitting `consent: {}`
        // races with the CMP's $consent_init and overwrites real consent data.
        let merged = Track.mergeUserProperties(
            perCall: ["email": "u@example.com"],
            defaultCustom: ["plan": "pro"],
            defaultConsent: [:])
        XCTAssertNil(merged?["consent"], "consent key must be omitted when both sides empty")
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
        XCTAssertEqual(p["version"] as? String, "swift@3.0.0")
        // device_type / os_name / os_version / screen_* depend on the host
        // platform; at minimum the cross-platform anchors must be present.
        // Legacy dollar-prefixed / snake_case keys must be absent.
        for legacy in ["$os", "$os_version", "$model", "$manufacturer", "mp_lib",
                       "$lib_version", "$screen_width", "$screen_height",
                       "$app_version_string", "$app_build_number"] {
            XCTAssertNil(p[legacy], "legacy key '\(legacy)' must not appear in defaultProperties")
        }
    }

    // MARK: - OursPrivacyUserProperties typed struct

    func testUserPropertiesStructMapsCamelToSnakeOnTheWire() {
        let typed = OursPrivacyUserProperties(
            email: "u@example.com",
            externalId: "ext-1",
            phoneNumber: "+1555",
            firstName: "Jane",
            lastName: "Doe",
            gender: "female",
            dateOfBirth: "1990-01-02",
            city: "Brooklyn",
            state: "NY",
            zip: "11201",
            country: "US",
            companyName: "Acme",
            jobTitle: "Engineer",
            ip: "1.2.3.4")
        let wire = typed.toWireProperties()
        XCTAssertEqual(wire["email"] as? String, "u@example.com")
        XCTAssertEqual(wire["external_id"] as? String, "ext-1")
        XCTAssertEqual(wire["phone_number"] as? String, "+1555")
        XCTAssertEqual(wire["first_name"] as? String, "Jane")
        XCTAssertEqual(wire["last_name"] as? String, "Doe")
        XCTAssertEqual(wire["gender"] as? String, "female")
        XCTAssertEqual(wire["date_of_birth"] as? String, "1990-01-02")
        XCTAssertEqual(wire["city"] as? String, "Brooklyn")
        XCTAssertEqual(wire["state"] as? String, "NY")
        XCTAssertEqual(wire["zip"] as? String, "11201")
        XCTAssertEqual(wire["country"] as? String, "US")
        XCTAssertEqual(wire["company_name"] as? String, "Acme")
        XCTAssertEqual(wire["job_title"] as? String, "Engineer")
        XCTAssertEqual(wire["ip"] as? String, "1.2.3.4")
        // No camelCase keys leak onto the wire.
        XCTAssertNil(wire["externalId"])
        XCTAssertNil(wire["phoneNumber"])
        XCTAssertNil(wire["firstName"])
        XCTAssertNil(wire["dateOfBirth"])
        XCTAssertNil(wire["companyName"])
        XCTAssertNil(wire["jobTitle"])
    }

    func testUserPropertiesStructPassesNestedDictsThrough() {
        let typed = OursPrivacyUserProperties(
            customProperties: ["tier": "gold"],
            consent: ["analytics": true])
        let wire = typed.toWireProperties()
        XCTAssertEqual((wire["custom_properties"] as? [String: OursPrivacyType])?["tier"] as? String, "gold")
        XCTAssertEqual((wire["consent"] as? [String: OursPrivacyType])?["analytics"] as? Bool, true)
    }

    func testUserPropertiesStructEmptyProducesEmptyDict() {
        let typed = OursPrivacyUserProperties()
        XCTAssertTrue(typed.toWireProperties().isEmpty)
    }

    // MARK: - Public setters (updateDefault*, setVisitorId, setLoggingEnabled)

    private func makeInstance() -> OursPrivacy {
        let token = "test-\(UUID().uuidString)"
        return OursPrivacy(token: token, trackAutomaticEvents: false)
    }

    func testUpdateDefaultEventPropertiesMergesPerCallWins() {
        let op = makeInstance()
        op.updateDefaultEventProperties(["release": "1.0", "page": "home"])
        op.updateDefaultEventProperties(["page": "checkout", "user_role": "admin"])
        let context = op.currentEventContext()
        XCTAssertEqual(context.defaultEventProperties["release"] as? String, "1.0")
        XCTAssertEqual(context.defaultEventProperties["page"] as? String, "checkout")
        XCTAssertEqual(context.defaultEventProperties["user_role"] as? String, "admin")
    }

    func testUpdateDefaultUserCustomPropertiesMerges() {
        let op = makeInstance()
        op.updateDefaultUserCustomProperties(["tier": "lite", "plan": "free"])
        op.updateDefaultUserCustomProperties(["tier": "gold"])
        let context = op.currentEventContext()
        XCTAssertEqual(context.userCustomProperties["tier"] as? String, "gold")
        XCTAssertEqual(context.userCustomProperties["plan"] as? String, "free")
    }

    func testUpdateDefaultUserConsentPropertiesMerges() {
        let op = makeInstance()
        op.updateDefaultUserConsentProperties(["analytics": true])
        op.updateDefaultUserConsentProperties(["marketing": false])
        let context = op.currentEventContext()
        XCTAssertEqual(context.userConsentProperties["analytics"] as? Bool, true)
        XCTAssertEqual(context.userConsentProperties["marketing"] as? Bool, false)
    }

    func testSetVisitorIdFlipsManuallySetFlag() {
        let op = makeInstance()
        XCTAssertFalse(op.isManuallySetId)
        op.setVisitorId("stitched-from-web-123")
        XCTAssertEqual(op.getVisitorId(), "stitched-from-web-123")
        XCTAssertTrue(op.isManuallySetId)
    }

    func testSetVisitorIdRejectsEmpty() {
        let op = makeInstance()
        let before = op.getVisitorId()
        op.setVisitorId("")
        XCTAssertEqual(op.getVisitorId(), before)
        XCTAssertFalse(op.isManuallySetId)
    }

    func testGetVisitorIdReturnsAutoGeneratedAfterConstruction() {
        let op = makeInstance()
        // The instance auto-generates a UUID at boot — `getVisitorId` should
        // return a non-nil, non-empty value even before any explicit identify.
        let id = op.getVisitorId()
        XCTAssertNotNil(id)
        XCTAssertFalse(id!.isEmpty)
    }

    func testSetLoggingEnabledFlipsTheProperty() {
        let op = makeInstance()
        XCTAssertFalse(op.loggingEnabled)
        op.setLoggingEnabled(true)
        XCTAssertTrue(op.loggingEnabled)
        op.setLoggingEnabled(false)
        XCTAssertFalse(op.loggingEnabled)
    }

    // MARK: - Attribution parser

    func testParseAttributionExtractsUtmParams() {
        let r = parseAttributionFromURL("https://app.example.com/?utm_source=newsletter&utm_medium=email&utm_campaign=launch")
        XCTAssertEqual(r.utmParams?["utm_source"], "newsletter")
        XCTAssertEqual(r.utmParams?["utm_medium"], "email")
        XCTAssertEqual(r.utmParams?["utm_campaign"], "launch")
        XCTAssertNil(r.clickIds)
        XCTAssertNil(r.oursVisitorId)
    }

    func testParseAttributionExtractsClickIds() {
        let r = parseAttributionFromURL("https://app.example.com/?gclid=ABC&fbclid=DEF&ttclid=GHI")
        XCTAssertEqual(r.clickIds?["gclid"], "ABC")
        XCTAssertEqual(r.clickIds?["fbclid"], "DEF")
        XCTAssertEqual(r.clickIds?["ttclid"], "GHI")
        XCTAssertNil(r.utmParams)
    }

    func testParseAttributionExtractsOursVisitorId() {
        let r = parseAttributionFromURL("https://app.example.com/?ours_visitor_id=stitched-abc")
        XCTAssertEqual(r.oursVisitorId, "stitched-abc")
    }

    func testParseAttributionIgnoresUnknownKeys() {
        let r = parseAttributionFromURL("https://app.example.com/?random=foo&hello=world")
        XCTAssertNil(r.utmParams)
        XCTAssertNil(r.clickIds)
        XCTAssertNil(r.oursVisitorId)
    }

    func testParseAttributionHandlesUrlsWithoutQuery() {
        let r = parseAttributionFromURL("https://app.example.com/path")
        XCTAssertNil(r.utmParams)
        XCTAssertNil(r.clickIds)
        XCTAssertNil(r.oursVisitorId)
        XCTAssertEqual(r.rawURL, "https://app.example.com/path")
    }

    func testParseAttributionHandlesEmptyString() {
        let r = parseAttributionFromURL("")
        XCTAssertNil(r.utmParams)
        XCTAssertNil(r.clickIds)
        XCTAssertNil(r.oursVisitorId)
        XCTAssertEqual(r.rawURL, "")
    }

    func testParseAttributionDecodesPercentAndPlus() {
        let r = parseAttributionFromURL("https://app.example.com/?utm_campaign=spring%20sale&utm_term=hello+world")
        XCTAssertEqual(r.utmParams?["utm_campaign"], "spring sale")
        XCTAssertEqual(r.utmParams?["utm_term"], "hello world")
    }

    func testParseAttributionDropsFragmentBeforeQueryStop() {
        let r = parseAttributionFromURL("https://app.example.com/?utm_source=foo#section")
        XCTAssertEqual(r.utmParams?["utm_source"], "foo")
    }

    func testParseAttributionIgnoresEmptyValues() {
        let r = parseAttributionFromURL("https://app.example.com/?utm_source=&utm_medium=email")
        XCTAssertNil(r.utmParams?["utm_source"])
        XCTAssertEqual(r.utmParams?["utm_medium"], "email")
    }

    // MARK: - trackDeepLink

    func testTrackSnapshotsMutablePropertyBeforeQueuing() {
        let op = makeInstance()
        let mutableValue = NSMutableString(string: "before")
        op.trackingQueue.suspend()
        op.track(event: "Snapshot", properties: ["value": mutableValue])
        mutableValue.setString("after")
        op.trackingQueue.resume()
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let properties = events.first?["eventProperties"] as? [String: Any]
        XCTAssertEqual(properties?["value"] as? String, "before")
    }

    func testTrackSnapshotPreservesNestedUserProperties() {
        let op = makeInstance()
        let user = OursPrivacyUserProperties(
            externalId: "customer-1",
            customProperties: ["tier": "pro"],
            consent: ["analytics": true]
        )
        op.track(event: "Purchase", properties: ["sku": "A"], userProperties: user)
        op.trackingQueue.sync {}

        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let properties = events.first?["userProperties"] as? [String: Any]
        XCTAssertEqual(properties?["external_id"] as? String, "customer-1")
        XCTAssertEqual((properties?["custom_properties"] as? [String: Any])?["tier"] as? String, "pro")
        XCTAssertEqual((properties?["consent"] as? [String: Any])?["analytics"] as? Bool, true)
    }

    func testTrackDeepLinkReplacesAttributionDefaults() {
        let op = makeInstance()
        op.trackDeepLink("https://app.example.com/?utm_source=first&fbclid=stale")
        // Allow the trackingQueue to drain the queued track.
        op.trackingQueue.sync {}
        let ctxA = op.currentEventContext()
        XCTAssertEqual(ctxA.attributionDefaultProperties["utm_source"] as? String, "first")
        XCTAssertEqual(ctxA.attributionDefaultProperties["fbclid"] as? String, "stale")

        op.trackDeepLink("https://app.example.com/?utm_source=second")
        op.trackingQueue.sync {}
        let ctxB = op.currentEventContext()
        XCTAssertEqual(ctxB.attributionDefaultProperties["utm_source"] as? String, "second")
        // The stale click ID from the prior link must not survive — replace, not merge.
        XCTAssertNil(ctxB.attributionDefaultProperties["fbclid"])
    }

    func testTrackDeepLinkStitchesOursVisitorId() {
        let op = makeInstance()
        op.trackDeepLink("https://app.example.com/?ours_visitor_id=from-web-xyz")
        XCTAssertEqual(op.getVisitorId(), "from-web-xyz")
        XCTAssertTrue(op.isManuallySetId)
    }

    func testTrackDeepLinkRespectsOptOut() {
        let op = makeInstance()
        op.optOutTracking()
        op.trackingQueue.sync {}
        op.trackDeepLink("https://app.example.com/?utm_source=should-be-skipped")
        op.trackingQueue.sync {}
        let ctx = op.currentEventContext()
        XCTAssertNil(ctx.attributionDefaultProperties["utm_source"])
    }

    func testTrackDeepLinkSkipsEmptyUrl() {
        let op = makeInstance()
        op.trackDeepLink("")
        op.trackingQueue.sync {}
        let ctx = op.currentEventContext()
        XCTAssertTrue(ctx.attributionDefaultProperties.isEmpty)
    }

    // MARK: - Persistence (in-memory queue + UserDefaults blob)

    private func makePersistence() -> OursPrivacyPersistence {
        let instanceName = "persist-test-\(UUID().uuidString)"
        return OursPrivacyPersistence(instanceName: instanceName)
    }

    private func makeEntity(_ event: String) -> InternalProperties {
        [
            "event": event,
            "visitor_id": "v-\(UUID().uuidString)",
            "distinct_id": "d-\(UUID().uuidString)",
            "eventProperties": ["k": "v"] as InternalProperties,
            "userProperties": NSNull(),
            "defaultProperties": [:] as InternalProperties
        ]
    }

    func testQueueRoundTripsThroughUserDefaultsBlob() {
        let name = "rt-\(UUID().uuidString)"
        let first = OursPrivacyPersistence(instanceName: name)
        first.saveEntity(makeEntity("A"), type: .events)
        first.saveEntity(makeEntity("B"), type: .events)

        // Recreate the persistence object — simulates a fresh app launch.
        let second = OursPrivacyPersistence(instanceName: name)
        let loaded = second.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0]["event"] as? String, "A")
        XCTAssertEqual(loaded[1]["event"] as? String, "B")

        // Clean up so subsequent test runs don't see this queue.
        OursPrivacyPersistence.deleteUserDefaultsData(instanceName: name)
    }

    func testLegacyArrayQueueIsReadableAndCanAcceptNewItems() {
        let name = "legacy-queue-\(UUID().uuidString)"
        let key = "oursprivacy-\(name)-OPEventQueue"
        let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)
        defaults?.set(JSONHandler.serializeJSONObject([makeEntity("Before")]), forKey: key)
        let migrated = OursPrivacyPersistence(instanceName: name)
        XCTAssertEqual(migrated.loadEntitiesInBatch(type: .events).first?["event"] as? String, "Before")
        XCTAssertTrue(migrated.saveEntity(makeEntity("After"), type: .events))
        let restarted = OursPrivacyPersistence(instanceName: name)
        XCTAssertEqual(restarted.loadEntitiesInBatch(type: .events).compactMap { $0["event"] as? String },
                       ["Before", "After"])
        OursPrivacyPersistence.deleteUserDefaultsData(instanceName: name)
    }

    func testResetEntitiesClearsQueue() {
        let p = makePersistence()
        p.saveEntity(makeEntity("A"), type: .events)
        p.saveEntity(makeEntity("B"), type: .events)
        XCTAssertEqual(p.loadEntitiesInBatch(type: .events).count, 2)
        p.resetEntities()
        XCTAssertEqual(p.loadEntitiesInBatch(type: .events).count, 0)
        OursPrivacyPersistence.deleteUserDefaultsData(instanceName: p.instanceName)
    }

    func testRemoveEntitiesByIdDrainsQueue() {
        let p = makePersistence()
        p.saveEntity(makeEntity("A"), type: .events)
        p.saveEntity(makeEntity("B"), type: .events)
        p.saveEntity(makeEntity("C"), type: .events)
        let loaded = p.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(loaded.count, 3)
        let firstTwoIds = loaded.prefix(2).compactMap { $0["id"] as? Int32 }
        XCTAssertEqual(firstTwoIds.count, 2)

        p.removeEntitiesInBatch(type: .events, ids: firstTwoIds)
        let remaining = p.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0]["event"] as? String, "C")

        OursPrivacyPersistence.deleteUserDefaultsData(instanceName: p.instanceName)
    }

    func testLoadEntitiesInBatchRespectsBatchSize() {
        let p = makePersistence()
        for event in ["A", "B", "C", "D"] {
            p.saveEntity(makeEntity(event), type: .events)
        }
        XCTAssertEqual(p.loadEntitiesInBatch(type: .events, batchSize: 2).count, 2)
        XCTAssertEqual(p.loadEntitiesInBatch(type: .events, batchSize: 10).count, 4)
        OursPrivacyPersistence.deleteUserDefaultsData(instanceName: p.instanceName)
    }

    func testExcludeAutomaticEventsFiltersAEPrefix() {
        let p = makePersistence()
        p.saveEntity(makeEntity("$ae_session"), type: .events)
        p.saveEntity(makeEntity("Purchase"), type: .events)
        let filtered = p.loadEntitiesInBatch(type: .events, excludeAutomaticEvents: true)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0]["event"] as? String, "Purchase")
        OursPrivacyPersistence.deleteUserDefaultsData(instanceName: p.instanceName)
    }

    func testOptOutTrackingClearsQueue() {
        let op = makeInstance()
        op.track(event: "before-opt-out")
        op.trackingQueue.sync {}
        XCTAssertGreaterThan(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 0)

        op.optOutTracking()
        op.trackingQueue.sync {}
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 0)
    }

    // MARK: - optedOutByDefault initialization option

    func testOptedOutByDefaultTrueSkipsTrackingOnFirstLaunch() async {
        let op = makeInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        XCTAssertTrue(op.hasOptedOutTracking())

        op.track(event: "should-be-dropped")
        op.trackingQueue.sync {}
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 0)
    }

    func testOptedOutByDefaultFalseAllowsTracking() async {
        let op = makeInstance()
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: false))
        XCTAssertFalse(op.hasOptedOutTracking())

        op.track(event: "should-be-kept")
        op.trackingQueue.sync {}
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 1)
    }

    func testOptedOutByDefaultDoesNotOverridePersistedOptIn() async {
        let op = makeInstance()
        op.optInTracking()
        op.trackingQueue.sync {}
        XCTAssertFalse(op.hasOptedOutTracking())

        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        XCTAssertFalse(op.hasOptedOutTracking())
    }

    private func makeMobileInstance(name: String = "mobile-\(UUID().uuidString)") -> OursPrivacy {
        let op = OursPrivacy(token: name, trackAutomaticEvents: true)
        op.mobileSession = MobileSession(instanceName: name)
        op.mobileRuntimeEnabled = true
        return op
    }

    private func mobilePoint(_ elapsed: Int64 = 0) -> MobileTimePoint {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return MobileTimePoint(epochMs: now + elapsed, monotonicMs: elapsed)
    }

    func testInitialLinkPrecedesCanonicalOpenAndManualBookingKeepsCallerFields() async {
        let op = makeMobileInstance()
        let openedAt = mobilePoint()
        op.mobileForeground(at: openedAt)
        await op.initialize(options: OursPrivacyInitOptions(
            initialURL: "https://example.test/?ours_visitor_id=stitched-ios&utm_source=campaign",
            defaultEventProperties: ["caller_field": "event"],
            defaultUserCustomProperties: ["patient_field": "private"]))
        op.track(event: "appointment_booked", properties: ["appointment_id": "visit-1"])
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let canonical = items.filter { ($0["event"] as? String)?.hasPrefix("$mobile_") == true }
        XCTAssertEqual(canonical.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start"])
        let booked = items.first { $0["event"] as? String == "appointment_booked" }
        let sid = (canonical.first?["defaultProperties"] as? [String: Any])?["sid"] as? String
        XCTAssertNotNil(sid)
        XCTAssertEqual((booked?["defaultProperties"] as? [String: Any])?["sid"] as? String, sid)
        let timestampPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        for item in canonical + (booked.map { [$0] } ?? []) {
            XCTAssertEqual(item["visitor_id"] as? String, "stitched-ios")
            XCTAssertNil(item["time"])
            let defaults = item["defaultProperties"] as? [String: Any]
            XCTAssertEqual(defaults?["mobile_platform"] as? String, "ios")
            XCTAssertEqual(defaults?["mobile_contract_version"] as? Int, 1)
            XCTAssertNotNil((defaults?["mobile_occurred_at"] as? String)?
                .range(of: timestampPattern, options: .regularExpression))
            XCTAssertNotNil((defaults?["mobile_session_started_at"] as? String)?
                .range(of: timestampPattern, options: .regularExpression))
            XCTAssertEqual(defaults?["version"] as? String, "swift@3.0.0")
            if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                XCTAssertEqual(defaults?["app_version"] as? String, appVersion)
            }
            if let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                XCTAssertEqual(defaults?["app_build"] as? String, appBuild)
            }
        }
        for item in canonical {
            XCTAssertTrue(item["userProperties"] is NSNull)
            XCTAssertTrue(item["eventProperties"] is NSNull)
            XCTAssertNil((item["defaultProperties"] as? [String: Any])?["utm_source"])
        }
        XCTAssertEqual((booked?["eventProperties"] as? [String: Any])?["caller_field"] as? String, "event")
        XCTAssertEqual(((booked?["userProperties"] as? [String: Any])?["custom_properties"] as?
                        [String: Any])?["patient_field"] as? String, "private")
        XCTAssertEqual((booked?["defaultProperties"] as? [String: Any])?["utm_source"] as? String, "campaign")
    }

    func testMobileEngagementUsesCallbackTimeAndDuplicateForegroundIsIgnored() async {
        let op = makeMobileInstance()
        await op.initialize()
        let start = mobilePoint()
        op.mobileForeground(at: start)
        op.mobileForeground(at: MobileTimePoint(epochMs: start.epochMs + 1_000, monotonicMs: 1_000))
        op.mobileQueueNowMs = { start.epochMs + 10_000 }
        op.mobileBackground(at: MobileTimePoint(epochMs: start.epochMs + 10_000, monotonicMs: 10_000))
        op.trackingQueue.sync {}
        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(items.filter { $0["event"] as? String == "$mobile_app_open" }.count, 1)
        let engagement = items.first { $0["event"] as? String == "$mobile_session_engagement" }
        XCTAssertEqual((engagement?["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int64,
                       10_000)
    }

    func testManualMobileEventHasSessionWithAutomaticEventsOff() async {
        let op = makeMobileInstance()
        op.trackAutomaticEventsEnabled = false
        await op.initialize()
        op.track(event: "appointment_booked")
        op.identify(OursPrivacyUserProperties(externalId: "external-1"))
        op.trackingQueue.sync {}
        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(items.count, 2)
        XCTAssertNotNil((items[0]["defaultProperties"] as? [String: Any])?["sid"] as? String)
        XCTAssertEqual((items[1]["defaultProperties"] as? [String: Any])?["sid"] as? String,
                       (items[0]["defaultProperties"] as? [String: Any])?["sid"] as? String)
        XCTAssertEqual((items[1]["defaultProperties"] as? [String: Any])?["mobile_platform"] as? String, "ios")
    }

    func testAcceptedFirstOpenSurvivesQueueRemovalAndOptOutRestart() async {
        let name = "mobile-\(UUID().uuidString)"
        let first = makeMobileInstance(name: name)
        await first.initialize()
        first.mobileForeground(at: mobilePoint())
        first.trackingQueue.sync {}
        let queued = first.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(queued.filter { $0["event"] as? String == "$mobile_first_open" }.count, 1)
        first.oursprivacyPersistence.removeEntitiesInBatch(
            type: .events, ids: queued.compactMap { $0["id"] as? Int32 })
        first.optOutTracking()
        first.trackingQueue.sync {}
        let second = makeMobileInstance(name: name)
        await second.initialize()
        second.optInTracking()
        second.trackingQueue.sync {}
        second.mobileForeground(at: mobilePoint())
        second.trackingQueue.sync {}
        let replay = second.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertFalse(replay.contains { $0["event"] as? String == "$mobile_first_open" })
    }

    func testFailedQueueWriteKeepsFirstOpenEligible() async {
        let op = makeMobileInstance()
        await op.initialize()
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.mobileForeground(at: mobilePoint())
        op.trackingQueue.sync {}
        XCTAssertFalse(op.mobileSession?.hasAcceptedFirstOpen ?? true)
        XCTAssertTrue(op.mobileSession?.pendingFacts.contains {
            $0.name == "$mobile_first_open"
        } ?? false)
    }

    func testFailedFirstOpenWriteHoldsLaterLifecycleFactsUntilRetry() async {
        let op = makeMobileInstance()
        await op.initialize()
        let persist = op.oursprivacyPersistence.persistenceWrite
        var attempts = 0
        op.oursprivacyPersistence.persistenceWrite = { data in
            attempts += 1
            return attempts == 1 ? false : persist(data)
        }
        op.mobileForeground(at: mobilePoint())
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        XCTAssertFalse(op.mobileSession?.hasAcceptedFirstOpen ?? true)

        op.track(event: "appointment_booked")
        op.trackingQueue.sync {}
        let names = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .compactMap { $0["event"] as? String }
        XCTAssertEqual(names, ["$mobile_first_open", "$mobile_app_open",
                               "$mobile_session_start", "appointment_booked"])
    }

    func testFailedFirstOpenWriteRetriesWithoutAnotherEvent() async {
        let op = makeMobileInstance()
        await op.initialize()
        op.mobilePendingRetryIntervalMs = 25
        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.mobileForeground(at: mobilePoint())
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        XCTAssertFalse(op.mobileSession?.hasAcceptedFirstOpen ?? true)

        op.oursprivacyPersistence.persistenceWrite = persist
        for _ in 0 ..< 50 {
            if op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count == 3 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let queued = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(queued.compactMap { $0["event"] as? String },
                       ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start"])
        XCTAssertTrue(op.mobileSession?.hasAcceptedFirstOpen ?? false)
    }

    func testQueueEvidenceSurvivesMissingSessionAcknowledgmentAndRestart() async {
        let name = "mobile-\(UUID().uuidString)"
        let session = MobileSession(instanceName: name)
        let first = session.foreground(automaticEnabled: true, visitorId: "original-visitor",
                                       appVersion: "2.0", appBuild: "42", at: mobilePoint())[0]
        let persistence = OursPrivacyPersistence(instanceName: name)
        XCTAssertTrue(persistence.saveEntity(Track().composeMobileFact(first), type: .events,
                                             firstOpen: true))
        XCTAssertFalse(session.hasAcceptedFirstOpen)
        let sent = persistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(sent.first?["visitor_id"] as? String, "original-visitor")
        XCTAssertEqual((sent.first?["defaultProperties"] as? [String: Any])?["app_version"] as? String, "2.0")
        persistence.removeEntitiesInBatch(type: .events,
                                          ids: sent.compactMap { $0["id"] as? Int32 })

        let restarted = makeMobileInstance(name: name)
        await restarted.initialize()
        restarted.optOutTracking()
        restarted.trackingQueue.sync {}
        restarted.optInTracking()
        restarted.trackingQueue.sync {}
        restarted.mobileForeground(at: mobilePoint())
        restarted.trackingQueue.sync {}
        let replay = restarted.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertFalse(replay.contains { $0["event"] as? String == "$mobile_first_open" })
        XCTAssertTrue(restarted.mobileSession?.hasAcceptedFirstOpen ?? false)
    }

    func testResetDropsUnqueuedOldIdentityFactsAndKeepsFirstOpenEligible() async {
        let op = makeMobileInstance()
        await op.initialize()
        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.mobileForeground(at: mobilePoint())
        op.trackingQueue.sync {}
        let originalFirstOpen = op.mobileSession?.pendingFacts.first {
            $0.name == "$mobile_first_open"
        }?.distinctId
        XCTAssertNotNil(originalFirstOpen)

        op.reset()
        op.trackingQueue.sync {}
        op.oursprivacyPersistence.persistenceWrite = persist
        op.track(event: "appointment_booked")
        op.trackingQueue.sync {}
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertFalse(events.contains { $0["distinct_id"] as? String == originalFirstOpen })
        XCTAssertFalse(op.mobileSession?.hasAcceptedFirstOpen ?? true)
        let booked = events.first { $0["event"] as? String == "appointment_booked" }
        XCTAssertNotNil((booked?["defaultProperties"] as? [String: Any])?["sid"] as? String)
    }

    func testFuturePendingFactsWaitUntilTheirOccurrenceTime() async {
        let name = "mobile-\(UUID().uuidString)"
        let op = makeMobileInstance(name: name)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let future = MobileTimePoint(epochMs: now + 60_000, monotonicMs: 0)
        _ = op.mobileSession?.foreground(automaticEnabled: true, visitorId: "visitor-a", at: future)
        op.mobileQueueNowMs = { now }
        await op.initialize()
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        op.mobileQueueNowMs = { now + 59_999 }
        op.mobileForeground(at: future)
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        op.mobileQueueNowMs = { now + 60_000 }
        op.mobileForeground(at: future)
        op.trackingQueue.sync {}
        let accepted = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(accepted.filter { $0["event"] as? String == "$mobile_first_open" }.count, 1)
        XCTAssertEqual(accepted.first?["visitor_id"] as? String, "visitor-a")
    }

    func testFutureFirstOpenBlocksNewLifecycleUntilScheduledRetryAfterRollback() async {
        let name = "mobile-\(UUID().uuidString)"
        let op = makeMobileInstance(name: name)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let clock = LockedMobileClock(now)
        op.mobileQueueNowMs = { clock.now() }
        op.mobilePendingRetryIntervalMs = 25
        let future = MobileTimePoint(epochMs: now + 10 * 60_000, monotonicMs: 0)
        let first = op.mobileSession?.foreground(automaticEnabled: true, visitorId: "original",
                                                 at: future).first
        XCTAssertEqual(first?.name, "$mobile_first_open")
        _ = op.mobileSession?.background(at: MobileTimePoint(epochMs: future.epochMs + 1_000,
                                                              monotonicMs: 1_000))
        await op.initialize()
        op.mobileForeground(at: MobileTimePoint(epochMs: now, monotonicMs: 2_000))
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        XCTAssertFalse(op.mobileSession?.hasAcceptedFirstOpen ?? true)

        clock.set(future.epochMs + 1_000)
        for _ in 0 ..< 50 {
            if !op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let queued = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(queued.first?["event"] as? String, "$mobile_first_open")
        XCTAssertEqual(queued.first?["distinct_id"] as? String, first?.distinctId)
        XCTAssertEqual(queued.first?["visitor_id"] as? String, "original")
        XCTAssertEqual(queued.filter { $0["event"] as? String == "$mobile_first_open" }.count, 1)
        XCTAssertTrue(queued.contains { $0["event"] as? String == "$mobile_app_open" })
    }

    func testOptOutClearsCanonicalAndManualQueueBeforeNextTracking() async {
        let op = makeMobileInstance()
        await op.initialize()
        op.mobileForeground(at: mobilePoint())
        op.track(event: "appointment_booked")
        op.trackingQueue.sync {}
        XCTAssertGreaterThan(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 1)

        op.optOutTracking()
        op.trackingQueue.sync {}
        op.mobileBackground(at: mobilePoint(10_000))
        op.track(event: "appointment_booked")
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        XCTAssertTrue(op.mobileSession?.pendingFacts.isEmpty ?? false)
    }

    func testResetRotatesManualSessionAndPreservesFirstOpenEvidence() async {
        let op = makeMobileInstance()
        await op.initialize()
        op.mobileForeground(at: mobilePoint())
        op.track(event: "appointment_booked")
        op.trackingQueue.sync {}
        let first = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let firstSid = (first.last?["defaultProperties"] as? [String: Any])?["sid"] as? String
        XCTAssertNotNil(firstSid)

        op.reset()
        op.trackingQueue.sync {}
        op.track(event: "appointment_booked")
        op.trackingQueue.sync {}
        let later = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let laterSid = (later.last?["defaultProperties"] as? [String: Any])?["sid"] as? String
        XCTAssertNotNil(laterSid)
        XCTAssertNotEqual(firstSid, laterSid)
        XCTAssertTrue(op.oursprivacyPersistence.hasFirstOpenQueueEvidence)
        XCTAssertFalse(later.contains { $0["event"] as? String == "$mobile_app_open" })
    }

    func testPendingFirstOpenKeepsOriginalVisitorAfterIdentityChange() async {
        let op = makeMobileInstance()
        await op.initialize()
        let originalVisitor = op.visitorId
        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.mobileForeground(at: mobilePoint())
        op.trackingQueue.sync {}
        let pending = op.mobileSession?.pendingFacts.first { $0.name == "$mobile_first_open" }
        XCTAssertNotNil(pending)

        op.oursprivacyPersistence.persistenceWrite = persist
        op.setVisitorId("new-visitor")
        op.track(event: "appointment_booked")
        op.trackingQueue.sync {}
        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let firstOpen = items.first { $0["event"] as? String == "$mobile_first_open" }
        let booked = items.first { $0["event"] as? String == "appointment_booked" }
        XCTAssertEqual(firstOpen?["distinct_id"] as? String, pending?.distinctId)
        XCTAssertEqual(firstOpen?["visitor_id"] as? String, originalVisitor)
        XCTAssertEqual((firstOpen?["defaultProperties"] as? [String: Any])?["sid"] as? String,
                       pending?.sid)
        XCTAssertEqual(booked?["visitor_id"] as? String, "new-visitor")
        XCTAssertNotEqual((booked?["defaultProperties"] as? [String: Any])?["sid"] as? String,
                          pending?.sid)
    }

    func testFailedOptOutClearCannotSendOldEventsAfterOptIn() async {
        let op = makeMobileInstance()
        await op.initialize()
        op.mobileForeground(at: mobilePoint())
        op.track(event: "before-opt-out", properties: ["private": "old"])
        op.trackingQueue.sync {}
        let old = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertTrue(op.oursprivacyPersistence.hasFirstOpenQueueEvidence)
        let request = RecordingFlushRequest(serverURL: op.serverURL)
        op.flushInstance.flushRequest = request

        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.optOutTracking()
        op.trackingQueue.sync {}
        XCTAssertFalse(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        op.optInTracking()
        op.trackingQueue.sync {}
        XCTAssertTrue(op.hasOptedOutTracking())
        op.flushQueue(old, type: .events)
        XCTAssertTrue(request.sentBodies.isEmpty)

        op.oursprivacyPersistence.persistenceWrite = persist
        op.optInTracking()
        op.trackingQueue.sync {}
        XCTAssertFalse(op.hasOptedOutTracking())
        XCTAssertTrue(op.oursprivacyPersistence.hasFirstOpenQueueEvidence)
        let after = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertFalse(after.contains { $0["event"] as? String == "before-opt-out" })
        XCTAssertFalse(after.contains { $0["event"] as? String == "$mobile_first_open" })
        op.flushQueue(old, type: .events)
        op.flushQueue(after, type: .events)
        XCTAssertFalse(request.sentBodies.joined().contains("before-opt-out"))
        XCTAssertFalse(request.sentBodies.joined().contains("\"private\":\"old\""))
    }

    func testFailedResetClearBlocksSendsUntilStorageRecovers() {
        let op = makeInstance()
        op.track(event: "before-reset", properties: ["private": "old"])
        op.trackingQueue.sync {}
        let old = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let request = RecordingFlushRequest(serverURL: op.serverURL)
        op.flushInstance.flushRequest = request
        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }

        op.reset()
        op.trackingQueue.sync {}
        op.networkQueue.sync {}
        op.flushQueue(old, type: .events)
        XCTAssertTrue(request.sentBodies.isEmpty)
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 1)

        op.oursprivacyPersistence.persistenceWrite = persist
        op.track(event: "after-reset")
        op.trackingQueue.sync {}
        let after = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(after.compactMap { $0["event"] as? String }, ["after-reset"])
        op.flushQueue(old, type: .events)
        op.flushQueue(after, type: .events)
        XCTAssertFalse(request.sentBodies.joined().contains("before-reset"))
    }

    func testOptOutStopsLaterBatchesAfterFirstRequestStarts() {
        let op = makeInstance()
        op.flushBatchSize = 1
        op.track(event: "old-first")
        op.track(event: "old-second")
        op.trackingQueue.sync {}
        let request = HeldFirstFlushRequest(serverURL: op.serverURL)
        op.flushInstance.flushRequest = request

        op.flush(performFullFlush: true)
        XCTAssertEqual(request.firstStarted.wait(timeout: .now() + 2), .success)
        op.optOutTracking()
        op.trackingQueue.sync {}
        request.releaseFirst.signal()
        op.networkQueue.sync {}
        op.trackingQueue.sync {}

        XCTAssertEqual(request.sentBodies.count, 1)
        XCTAssertFalse(request.sentBodies.joined().contains("old-second"))
    }

    func testResetStopsLaterBatchesAndOldAckCannotDeleteReusedRow() {
        let op = makeInstance()
        op.flushBatchSize = 1
        op.track(event: "old-first", properties: ["$distinct_id": "reused"])
        op.track(event: "old-second")
        op.trackingQueue.sync {}
        let oldId = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).first?["id"] as? Int32
        let request = HeldFirstFlushRequest(serverURL: op.serverURL)
        op.flushInstance.flushRequest = request

        op.flush(performFullFlush: true)
        XCTAssertEqual(request.firstStarted.wait(timeout: .now() + 2), .success)
        op.reset()
        op.trackingQueue.sync {}
        op.track(event: "replacement", properties: ["$distinct_id": "reused"])
        op.trackingQueue.sync {}
        let replacement = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(replacement.first?["id"] as? Int32, oldId)
        XCTAssertEqual(replacement.first?["distinct_id"] as? String, "reused")

        request.releaseFirst.signal()
        op.networkQueue.sync {}
        op.trackingQueue.sync {}

        XCTAssertEqual(request.sentBodies.count, 1)
        XCTAssertFalse(request.sentBodies.joined().contains("old-second"))
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .first?["event"] as? String, "replacement")
    }

    func testResetRejectsCapturedPayloadWithReusedDistinctAndRowId() {
        let op = makeInstance()
        op.track(event: "old-private", properties: ["$distinct_id": "reused"])
        op.trackingQueue.sync {}
        let captured = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let oldId = captured.first?["id"] as? Int32
        let request = RecordingFlushRequest(serverURL: op.serverURL)
        op.flushInstance.flushRequest = request

        op.reset()
        op.trackingQueue.sync {}
        op.track(event: "replacement", properties: ["$distinct_id": "reused"])
        op.trackingQueue.sync {}
        let replacement = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(replacement.first?["id"] as? Int32, oldId)
        op.flushQueue(captured, type: .events)
        op.trackingQueue.sync {}

        XCTAssertTrue(request.sentBodies.isEmpty)
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .first?["event"] as? String, "replacement")
    }

    func testFlushNeverSendsLocalRowIdentity() {
        let op = makeInstance()
        var event = makeEntity("manual")
        event["op_local_row_id"] = "local-secret"
        XCTAssertTrue(op.oursprivacyPersistence.saveEntity(event, type: .events))
        let request = RecordingFlushRequest(serverURL: op.serverURL)
        op.flushInstance.flushRequest = request

        op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
        XCTAssertEqual(request.sentBodies.count, 1)
        XCTAssertFalse(request.sentBodies.joined().contains("op_local_row_id"))
        XCTAssertFalse(request.sentBodies.joined().contains("local-secret"))
    }

    func testLocalRowIdentitySurvivesQueueRestart() {
        let name = "row-restart-\(UUID().uuidString)"
        let original = OursPrivacyPersistence(instanceName: name)
        XCTAssertTrue(original.saveEntity(makeEntity("persisted"), type: .events))
        let before = original.loadEntitiesInBatch(type: .events).first?["op_local_row_id"] as? String
        let restarted = OursPrivacyPersistence(instanceName: name)
        let after = restarted.loadEntitiesInBatch(type: .events).first?["op_local_row_id"] as? String
        XCTAssertNotNil(before)
        XCTAssertEqual(after, before)
        OursPrivacyPersistence.deleteUserDefaultsData(instanceName: name)
    }

    func testFailedClearStillAppliesBackgroundBeforeNextForeground() async {
        let op = makeMobileInstance()
        await op.initialize()
        let origin = Int64(Date().timeIntervalSince1970 * 1_000)
        op.mobileQueueNowMs = { origin + 80_000 }
        op.mobileForeground(at: MobileTimePoint(epochMs: origin, monotonicMs: 0))
        op.trackingQueue.sync {}
        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.captureMobileTime = { MobileTimePoint(epochMs: origin + 5_000, monotonicMs: 5_000) }
        op.reset()
        op.trackingQueue.sync {}
        op.mobileBackground(at: MobileTimePoint(epochMs: origin + 10_000, monotonicMs: 10_000))
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.hasPendingPrivacyClear)

        op.oursprivacyPersistence.persistenceWrite = persist
        op.mobileForeground(at: MobileTimePoint(epochMs: origin + 60_000, monotonicMs: 60_000))
        op.mobileBackground(at: MobileTimePoint(epochMs: origin + 70_000, monotonicMs: 70_000))
        op.trackingQueue.sync {}
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let durations = events.filter { $0["event"] as? String == "$mobile_session_engagement" }
            .compactMap { ($0["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int64 }
        XCTAssertEqual(durations, [5_000, 10_000])
        XCTAssertEqual(events.filter { $0["event"] as? String == "$mobile_app_open" }.count, 1)
    }

    func testFailedPrivacyClearRecoversOnRestartAndPreservesFirstOpenEvidence() {
        let name = "privacy-recovery-\(UUID().uuidString)"
        let original = OursPrivacyPersistence(instanceName: name)
        XCTAssertTrue(original.saveEntity(makeEntity("$mobile_first_open"), type: .events,
                                          firstOpen: true))
        original.persistenceWrite = { _ in false }
        XCTAssertFalse(original.clearEntitiesForPrivacy())
        XCTAssertTrue(original.hasPendingPrivacyClear)

        let restarted = OursPrivacyPersistence(instanceName: name)
        XCTAssertFalse(restarted.hasPendingPrivacyClear)
        XCTAssertTrue(restarted.hasFirstOpenQueueEvidence)
        XCTAssertTrue(restarted.loadEntitiesInBatch(type: .events).isEmpty)
        OursPrivacyPersistence.deleteUserDefaultsData(instanceName: name)
    }

    func testBackgroundResetStartsManualSessionAtNextActivityAcrossMidnight() async {
        let op = makeMobileInstance()
        await op.initialize()
        let midnight: Int64 = 1_791_244_800_000
        let foreground = MobileTimePoint(epochMs: midnight - 60_000, monotonicMs: 0)
        op.mobileQueueNowMs = { midnight + 5 * 60_000 }
        op.mobileForeground(at: foreground)
        op.mobileBackground(at: MobileTimePoint(epochMs: midnight - 1_000, monotonicMs: 59_000))
        op.trackingQueue.sync {}
        op.captureMobileTime = {
            MobileTimePoint(epochMs: midnight + 60_000, monotonicMs: 120_000)
        }
        op.reset()
        op.trackingQueue.sync {}

        let nextActivity = midnight + 5 * 60_000
        op.captureMobileTime = {
            MobileTimePoint(epochMs: nextActivity, monotonicMs: 360_000)
        }
        op.track(event: "appointment_booked")
        op.trackingQueue.sync {}
        let booking = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .first { $0["event"] as? String == "appointment_booked" }
        let defaults = booking?["defaultProperties"] as? [String: Any]
        XCTAssertNotNil(defaults?["sid"] as? String)
        XCTAssertEqual(defaults?["mobile_session_started_at"] as? String,
                       defaults?["mobile_occurred_at"] as? String)
    }

    func testWipeLegacySQLiteFileIfPresent() {
        let manager = FileManager.default
        let instanceName = "legacy-wipe-\(UUID().uuidString)"
        let sanitized = String(instanceName.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
#if os(iOS)
        let directory = manager.urls(for: .libraryDirectory, in: .userDomainMask).last!
#else
        let directory = manager.urls(for: .cachesDirectory, in: .userDomainMask).last!
#endif
        let filePath = directory.appendingPathComponent("\(sanitized)_OPDB.sqlite").path
        try? manager.removeItem(atPath: filePath)
        manager.createFile(atPath: filePath, contents: Data("legacy".utf8))
        XCTAssertTrue(manager.fileExists(atPath: filePath))

        OursPrivacyPersistence.wipeLegacySQLiteFileIfPresent(instanceName: instanceName)
        XCTAssertFalse(manager.fileExists(atPath: filePath))
    }
}
