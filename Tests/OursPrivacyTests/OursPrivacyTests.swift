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

    // MARK: - OursPrivacyUserProperties typed struct

    func testUserPropertiesStructMapsCamelToSnakeOnTheWire() {
        let typed = OursPrivacyUserProperties(
            email: "u@example.com",
            externalId: "ext-1",
            phoneNumber: "+1555",
            firstName: "Jane",
            lastName: "Doe")
        let wire = typed.toWireProperties()
        XCTAssertEqual(wire["email"] as? String, "u@example.com")
        XCTAssertEqual(wire["external_id"] as? String, "ext-1")
        XCTAssertEqual(wire["phone_number"] as? String, "+1555")
        XCTAssertEqual(wire["first_name"] as? String, "Jane")
        XCTAssertEqual(wire["last_name"] as? String, "Doe")
        // No camelCase keys leak onto the wire.
        XCTAssertNil(wire["externalId"])
        XCTAssertNil(wire["phoneNumber"])
        XCTAssertNil(wire["firstName"])
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
            "defaultProperties": [:] as InternalProperties,
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
