import Foundation
import XCTest
@testable import OursPrivacyKit

final class MobilePayloadCompatibilityTests: XCTestCase {
    func testManualMetadataFallsBackForValidCallerBagNearSerializedSizeLimit() throws {
        let ordinary = ["field": String(repeating: "a", count: 1_048_563)]
        XCTAssertEqual(try XCTUnwrap(JSONHandler.encodeAPIData(ordinary)).utf16.count, 1_048_575)
        for appMetadata in [false, true] {
            let snapshot = MobileSessionSnapshot(
                sid: "1791194400000", visitorId: "visitor", startedAtMs: 1_791_194_400_000,
                occurredAtMs: 1_791_194_401_000, appVersion: appMetadata ? "2.3" : nil,
                appBuild: appMetadata ? "45" : nil)
            var enriched: InternalProperties = ordinary
            enriched += snapshot.eventProperties
            XCTAssertGreaterThan(try XCTUnwrap(JSONHandler.encodeAPIData(enriched)).utf16.count, 1_048_576)
            let context = EventContext(
                visitorId: "visitor", defaultEventProperties: [:], userCustomProperties: [:],
                userConsentProperties: [:], attributionDefaultProperties: [:], mobileSnapshot: snapshot)

            let item = Track().composeTrackEvent(
                event: "large-booking", eventProperties: ordinary.mapValues { $0 as OursPrivacyType },
                userProperties: nil, context: context)
            let properties = try XCTUnwrap(item["eventProperties"] as? InternalProperties)

            XCTAssertTrue(properties as NSDictionary == ordinary as NSDictionary)
            XCTAssertEqual(try XCTUnwrap(JSONHandler.encodeAPIData(properties)).utf16.count, 1_048_575)
            XCTAssertEqual((item["defaultProperties"] as? InternalProperties)?["sid"] as? String, "1791194400000")
            XCTAssertEqual((item["defaultProperties"] as? InternalProperties)?["version"] as? String, "swift@3.1.0")
        }
    }

    func testManualMetadataUsesStrictUTF16SerializedSizeBoundary() throws {
        let snapshot = MobileSessionSnapshot(
            sid: "1791194400000", visitorId: "visitor", startedAtMs: 1_791_194_400_000,
            occurredAtMs: 1_791_194_401_000, appVersion: "2.3", appBuild: "45")
        var emptyCandidate: InternalProperties = ["field": ""]
        emptyCandidate += snapshot.eventProperties
        let overhead = try XCTUnwrap(JSONHandler.encodeAPIData(emptyCandidate)).utf16.count
        let context = EventContext(
            visitorId: "visitor", defaultEventProperties: [:], userCustomProperties: [:],
            userConsentProperties: [:], attributionDefaultProperties: [:], mobileSnapshot: snapshot)
        for symbol in ["a", "😀"] {
            for (candidateLength, versioned) in [(1_048_575, true), (1_048_576, false)] {
                let padding = candidateLength - overhead
                let ordinary = ["field": String(repeating: symbol, count: padding / symbol.utf16.count)
                    + String(repeating: "a", count: padding % symbol.utf16.count)]
                var candidate: InternalProperties = ordinary
                candidate += snapshot.eventProperties
                let encoded = try XCTUnwrap(JSONHandler.encodeAPIData(candidate))
                XCTAssertEqual(encoded.utf16.count, candidateLength)
                if symbol == "😀" {
                    XCTAssertGreaterThan(encoded.utf8.count, 1_048_576)
                    XCTAssertLessThan(encoded.count, 1_048_576)
                }

                let item = Track().composeTrackEvent(
                    event: "large-booking", eventProperties: ordinary.mapValues { $0 as OursPrivacyType },
                    userProperties: nil, context: context)
                let properties = try XCTUnwrap(item["eventProperties"] as? InternalProperties)

                XCTAssertTrue(properties["field"] as? String == ordinary["field"])
                XCTAssertEqual(properties.count, versioned ? 5 : 1)
                XCTAssertEqual(properties["mobile_contract_version"] as? Int, versioned ? 1 : nil)
                XCTAssertLessThan(try XCTUnwrap(JSONHandler.encodeAPIData(properties)).utf16.count, 1_048_576)
            }
        }
    }

    func testIdentifyAndCanonicalFactsKeepMetadataWithFullCallerDefaults() throws {
        let name = "canonical-capacity-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)?
                .removeObject(forKey: "oursprivacy-\(name)-OPMobileSession")
        }
        let session = MobileSession(instanceName: name)
        let point = MobileTimePoint(epochMs: 1_791_194_400_000, monotonicMs: 0)
        let facts = session.foreground(automaticEnabled: true, visitorId: "visitor",
                                       appVersion: "2.3", appBuild: "45", at: point)
        let context = EventContext(
            visitorId: "visitor",
            defaultEventProperties: Dictionary(uniqueKeysWithValues: (0 ..< 200).map { ("field_\($0)", $0) }),
            userCustomProperties: ["patient_field": "sample"], userConsentProperties: [:],
            attributionDefaultProperties: ["utm_source": "campaign"],
            mobileSnapshot: session.snapshot(visitorId: "visitor", appVersion: "2.3", appBuild: "45", at: point))
        let track = Track()
        let identify = track.composeIdentifyEvent(userProperties: ["external_id": "profile"], context: context)
        let canonical = facts.map(track.composeMobileFact)
        for item in canonical + [identify] {
            let properties = try XCTUnwrap(item["eventProperties"] as? InternalProperties)
            XCTAssertEqual(properties.count, 4)
            XCTAssertEqual(properties["mobile_contract_version"] as? Int, 1)
            XCTAssertEqual(properties["app_version"] as? String, "2.3")
            XCTAssertEqual(properties["app_build"] as? String, "45")
        }
        XCTAssertTrue(canonical.allSatisfy { $0["userProperties"] is NSNull })
        XCTAssertTrue(canonical.allSatisfy { ($0["defaultProperties"] as? InternalProperties)?["utm_source"] == nil })
    }

    func testQueuedOverflowFromMobileMetadataIsNormalizedWithoutLosingCallerData() throws {
        for (legacy, sizeOverflow) in [(false, false), (true, false), (false, true), (true, true)] {
            let name = "queued-capacity-\(UUID().uuidString)"
            defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: name) }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName))
            let key = "oursprivacy-\(name)-OPEventQueue"
            let ordinary = sizeOverflow ? ["field": String(repeating: "a", count: 1_048_563)]
                : Dictionary(uniqueKeysWithValues: (0 ..< 200).map { ("field_\($0)", "value_\($0)") })
            let metadata: InternalProperties = [
                "mobile_contract_version": 1, "mobile_occurred_at": "2026-10-05T10:00:01.000Z",
                "app_version": "2.3", "app_build": "45"
            ]
            var properties: InternalProperties = ordinary
            var device: InternalProperties = ["sid": "1791194400000", "os_name": "iOS", "version": "swift@3.1.0"]
            if legacy {
                device += metadata
                device["sid"] = "D92E56DC-CFDA-4E5D-B58D-D9F0AB63C74C"
                device["mobile_session_started_at"] = "2026-10-05T10:00:00.000Z"
                device["mobile_platform"] = "ios"
            } else {
                properties += metadata
                XCTAssertEqual(properties.count, ordinary.count + 4)
            }
            let row: InternalProperties = [
                "id": 9, "op_local_row_id": "row-9", "op_local_identity_mode": false,
                "event": "appointment_booked", "distinct_id": "event-9", "visitor_id": "captured-visitor",
                "eventProperties": properties, "userProperties": ["external_id": "profile"],
                "defaultProperties": device
            ]
            defaults.set(try JSONSerialization.data(withJSONObject: ["events": [row], "firstOpenAccepted": true]), forKey: key)

            let store = OursPrivacyPersistence(instanceName: name)
            let migrated = try XCTUnwrap(store.loadEntitiesInBatch(type: .events).first)
            let normalized = try XCTUnwrap(migrated["eventProperties"] as? InternalProperties)
            XCTAssertEqual(normalized.count, ordinary.count)
            XCTAssertTrue(normalized as NSDictionary == ordinary as NSDictionary)
            XCTAssertLessThan(try XCTUnwrap(JSONHandler.encodeAPIData(normalized)).utf16.count, 1_048_576)
            XCTAssertEqual(migrated["visitor_id"] as? String, "captured-visitor")
            XCTAssertEqual(migrated["distinct_id"] as? String, "event-9")
            XCTAssertEqual(migrated["op_local_row_id"] as? String, "row-9")
            XCTAssertEqual(migrated["op_local_identity_mode"] as? Bool, false)
            XCTAssertEqual((migrated["defaultProperties"] as? InternalProperties)?["sid"] as? String, "1791194400000")
            XCTAssertEqual((migrated["defaultProperties"] as? InternalProperties)?["os_name"] as? String, "iOS")
            XCTAssertEqual((migrated["userProperties"] as? InternalProperties)?["external_id"] as? String, "profile")
            let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? InternalProperties)
            XCTAssertTrue(persisted["events"] as? NSArray == [migrated] as NSArray)
            XCTAssertTrue(OursPrivacyPersistence(instanceName: name).loadEntitiesInBatch(type: .events) as NSArray
                == [migrated] as NSArray)
        }
    }

    func testManualMetadataUsesCapacityAfterMergingAndRemovingReservedProperties() throws {
        let cases = [(196, true, true, 200), (197, true, false, 197), (200, true, false, 200),
                     (198, false, true, 200), (199, false, false, 199)]
        for (count, appMetadata, versioned, expectedCount) in cases {
            let ordinary = Dictionary(uniqueKeysWithValues: (0 ..< count).map { ("field_\($0)", "value_\($0)") })
            let snapshot = MobileSessionSnapshot(
                sid: "1791194400000", visitorId: "visitor", startedAtMs: 1_791_194_400_000,
                occurredAtMs: 1_791_194_401_000, appVersion: appMetadata ? "2.3" : nil,
                appBuild: appMetadata ? "45" : nil)
            var defaults: InternalProperties = ordinary.filter { Int($0.key.dropFirst(6))! < 100 }
            defaults["mobile_contract_version"] = 99
            defaults["mobile_platform"] = "spoofed"
            defaults["app_version"] = "spoofed"
            let context = EventContext(
                visitorId: "visitor", defaultEventProperties: defaults, userCustomProperties: [:],
                userConsentProperties: [:], attributionDefaultProperties: [:], mobileSnapshot: snapshot)
            var caller = ordinary.mapValues { $0 as OursPrivacyType }
            caller["$distinct_id"] = "event-id"
            caller["app_build"] = "spoofed"
            caller["mobile_occurred_at"] = "spoofed"
            caller["mobile_session_started_at"] = "spoofed"
            let item = Track().composeTrackEvent(
                event: "appointment_booked", eventProperties: caller,
                userProperties: ["external_id": "profile"], context: context)
            let properties = try XCTUnwrap(item["eventProperties"] as? InternalProperties)

            XCTAssertEqual(properties.count, expectedCount)
            XCTAssertEqual(properties.filter { $0.key.hasPrefix("field_") } as NSDictionary, ordinary as NSDictionary)
            XCTAssertEqual(properties["mobile_contract_version"] as? Int, versioned ? 1 : nil)
            if versioned {
                XCTAssertEqual(properties["mobile_occurred_at"] as? String, "2026-10-05T10:00:01.000Z")
                XCTAssertEqual(properties["app_version"] as? String, appMetadata ? "2.3" : nil)
                XCTAssertEqual(properties["app_build"] as? String, appMetadata ? "45" : nil)
            } else {
                for key in ["mobile_contract_version", "mobile_occurred_at", "app_version", "app_build"] {
                    XCTAssertNil(properties[key], key)
                }
            }
            XCTAssertNil(properties["mobile_platform"])
            XCTAssertNil(properties["mobile_session_started_at"])
            XCTAssertEqual(item["distinct_id"] as? String, "event-id")
            XCTAssertEqual((item["userProperties"] as? InternalProperties)?["external_id"] as? String, "profile")
            XCTAssertEqual((item["defaultProperties"] as? InternalProperties)?["sid"] as? String, "1791194400000")
            XCTAssertEqual((item["defaultProperties"] as? InternalProperties)?["version"] as? String, "swift@3.1.0")
        }
    }

    func testQueuedMobileUpgradePreservesIdentityAndHealthcareProperties() throws {
        let name = "queue-upgrade-\(UUID().uuidString)"
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName))
        let queueKey = "oursprivacy-\(name)-OPEventQueue"
        let events: [[String: Any]] = [
            [
                "id": 7, "op_local_row_id": "row-7", "distinct_id": "event-7", "visitor_id": "captured-visitor",
                "event": "appointment_booked",
                "eventProperties": ["appointment_id": "visit-1", "patient_field": "sample", "app_version": "spoofed"],
                "userProperties": ["external_id": "profile-1", "custom_properties": ["care_plan": "sample"]],
                "defaultProperties": [
                    "sid": "D92E56DC-CFDA-4E5D-B58D-D9F0AB63C74C",
                    "mobile_session_started_at": "2026-10-05T10:00:00.123Z",
                    "mobile_occurred_at": "2026-10-05T10:00:01.456Z",
                    "mobile_platform": "ios", "mobile_contract_version": 1,
                    "app_version": "2.3", "app_build": "45",
                    "os_name": "iOS", "device_vendor": "Apple", "version": "swift@3.1.0", "utm_source": "campaign"
                ]
            ],
            [
                "id": 8, "op_local_row_id": "row-8", "distinct_id": "event-8", "visitor_id": "captured-visitor",
                "event": "$mobile_screen_view", "eventProperties": ["screen_name": "Schedule"],
                "userProperties": NSNull(),
                "defaultProperties": [
                    "sid": "D92E56DC-CFDA-4E5D-B58D-D9F0AB63C74C",
                    "mobile_session_started_at": "not-a-date", "mobile_platform": "ios",
                    "mobile_occurred_at": "2026-10-05T10:00:01.456Z", "mobile_contract_version": 1
                ]
            ],
            [
                "id": 9, "op_local_row_id": "row-9", "distinct_id": "event-9", "visitor_id": "desktop-visitor",
                "event": "Desktop", "eventProperties": NSNull(), "userProperties": NSNull(),
                "defaultProperties": ["os_name": "macOS", "version": "swift@3.1.0"]
            ]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: ["events": events, "firstOpenAccepted": true]),
                     forKey: queueKey)

        let persistence = OursPrivacyPersistence(instanceName: name)
        let migrated = persistence.loadEntitiesInBatch(type: .events)
        XCTAssertTrue(persistence.hasFirstOpenQueueEvidence)
        XCTAssertEqual(migrated.count, 3)
        XCTAssertEqual(migrated[0]["distinct_id"] as? String, "event-7")
        XCTAssertEqual(migrated[0]["visitor_id"] as? String, "captured-visitor")
        XCTAssertEqual(migrated[0]["op_local_row_id"] as? String, "row-7")
        XCTAssertEqual((migrated[0]["id"] as? NSNumber)?.intValue, 7)
        let migratedDefaults = try XCTUnwrap(migrated[0]["defaultProperties"] as? [String: Any])
        let properties = try XCTUnwrap(migrated[0]["eventProperties"] as? [String: Any])
        XCTAssertEqual(migratedDefaults["sid"] as? String, "1791194400123")
        XCTAssertEqual(migratedDefaults["utm_source"] as? String, "campaign")
        XCTAssertEqual(migratedDefaults["os_name"] as? String, "iOS")
        XCTAssertEqual(properties["mobile_occurred_at"] as? String, "2026-10-05T10:00:01.456Z")
        XCTAssertEqual(properties["mobile_contract_version"] as? Int, 1)
        XCTAssertEqual(properties["app_version"] as? String, "2.3")
        XCTAssertEqual(properties["app_build"] as? String, "45")
        XCTAssertEqual(properties["patient_field"] as? String, "sample")
        XCTAssertEqual(properties["appointment_id"] as? String, "visit-1")
        XCTAssertEqual((migrated[0]["userProperties"] as? NSDictionary), events[0]["userProperties"] as? NSDictionary)
        for key in ["mobile_session_started_at", "mobile_platform", "mobile_occurred_at",
                    "mobile_contract_version", "app_version", "app_build"] {
            XCTAssertNil(migratedDefaults[key], key)
        }
        XCTAssertNil((migrated[1]["defaultProperties"] as? [String: Any])?["sid"])
        XCTAssertEqual((migrated[1]["eventProperties"] as? [String: Any])?["screen_name"] as? String, "Schedule")
        XCTAssertEqual(migrated[2] as NSDictionary, events[2] as NSDictionary)
        let restored = OursPrivacyPersistence(instanceName: name).loadEntitiesInBatch(type: .events)
        XCTAssertEqual(restored as NSArray, migrated as NSArray)
        let blob = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: queueKey))) as? [String: Any])
        XCTAssertEqual((blob["events"] as? NSArray), migrated as NSArray)
    }

    func testStoredUUIDSessionRestartsWithoutRepeatingAcceptedOrPendingFirstOpen() throws {
        for accepted in [false, true] {
            let name = "session-upgrade-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName))
            let key = "oursprivacy-\(name)-OPMobileSession"
            defer { defaults.removeObject(forKey: key) }
            let pending: [[String: Any]] = accepted ? [] : [[
                "name": "$mobile_first_open", "distinctId": "original-first-open",
                "visitorId": "original-visitor", "appVersion": "2.3", "appBuild": "45",
                "sid": "D92E56DC-CFDA-4E5D-B58D-D9F0AB63C74C",
                "startedAtMs": 1_791_194_400_000, "occurredAtMs": 1_791_194_400_123, "values": [:]
            ]]
            defaults.set(try JSONSerialization.data(withJSONObject: [
                "sid": "D92E56DC-CFDA-4E5D-B58D-D9F0AB63C74C",
                "startedAtMs": 1_791_194_400_000, "lastActiveAtMs": 1_791_194_400_000,
                "automaticStartSid": "D92E56DC-CFDA-4E5D-B58D-D9F0AB63C74C",
                "firstOpenAccepted": accepted, "pendingFacts": pending
            ]), forKey: key)

            let session = MobileSession(instanceName: name)
            let facts = session.foreground(
                automaticEnabled: true, visitorId: "current-visitor",
                at: MobileTimePoint(epochMs: 1_791_194_401_000, monotonicMs: 0))
            let opens = facts.filter { $0.name == "$mobile_first_open" }
            XCTAssertEqual(opens.count, accepted ? 0 : 1)
            XCTAssertEqual(facts.last?.name, "$mobile_session_start")
            XCTAssertEqual(facts.last?.sid, "1791194401000")
            if !accepted {
                let open = try XCTUnwrap(opens.first)
                XCTAssertEqual(open.sid, "1791194400000")
                XCTAssertEqual(open.distinctId, "original-first-open")
                XCTAssertEqual(open.visitorId, "original-visitor")
                let item = Track().composeMobileFact(open)
                XCTAssertEqual((item["eventProperties"] as? [String: Any])?["mobile_occurred_at"] as? String,
                               "2026-10-05T10:00:00.123Z")
                XCTAssertEqual((item["eventProperties"] as? [String: Any])?["app_version"] as? String, "2.3")
                let restored = MobileSession(instanceName: name)
                XCTAssertEqual(restored.pendingFacts.first?.sid, "1791194400000")
                XCTAssertEqual(restored.pendingFacts.first?.distinctId, "original-first-open")
            }
        }
    }

    func testManualAndIdentifyMetadataIsAuthoritativeInEventProperties() throws {
        let name = "wire-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)?
                .removeObject(forKey: "oursprivacy-\(name)-OPMobileSession")
        }
        let snapshot = MobileSession(instanceName: name).snapshot(
            visitorId: "visitor", appVersion: "2.3", appBuild: "45",
            at: MobileTimePoint(epochMs: 1_791_194_400_123, monotonicMs: 0))
        let context = EventContext(
            visitorId: "visitor",
            defaultEventProperties: ["mobile_contract_version": 99, "app_version": "spoofed", "clinic": "sample"],
            userCustomProperties: ["patient_field": "sample"],
            userConsentProperties: [:],
            attributionDefaultProperties: ["utm_source": "campaign"],
            mobileSnapshot: snapshot)
        let track = Track()
        let manual = track.composeTrackEvent(
            event: "appointment_booked",
            eventProperties: ["mobile_occurred_at": "spoofed", "app_build": "spoofed", "appointment_id": "visit-1"],
            userProperties: ["external_id": "profile-1"], context: context)
        let identify = track.composeIdentifyEvent(userProperties: ["external_id": "profile-1"], context: context)

        for item in [manual, identify] {
            let defaults = try XCTUnwrap(item["defaultProperties"] as? [String: Any])
            let properties = try XCTUnwrap(item["eventProperties"] as? [String: Any])
            XCTAssertEqual(defaults["sid"] as? String, "1791194400123")
            XCTAssertEqual(defaults["version"] as? String, "swift@3.1.0")
            XCTAssertEqual(defaults["device_vendor"] as? String, "Apple")
            XCTAssertEqual(defaults["utm_source"] as? String, "campaign")
            XCTAssertEqual(properties["mobile_contract_version"] as? Int, 1)
            XCTAssertEqual(properties["mobile_occurred_at"] as? String, "2026-10-05T10:00:00.123Z")
            XCTAssertEqual(properties["app_version"] as? String, "2.3")
            XCTAssertEqual(properties["app_build"] as? String, "45")
            for key in ["mobile_contract_version", "mobile_occurred_at", "app_version", "app_build",
                        "mobile_session_started_at", "mobile_platform"] {
                XCTAssertNil(defaults[key], key)
            }
            XCTAssertNil(properties["mobile_session_started_at"])
            XCTAssertNil(properties["mobile_platform"])
            XCTAssertEqual((item["userProperties"] as? [String: Any])?["external_id"] as? String, "profile-1")
        }
        XCTAssertEqual((manual["eventProperties"] as? [String: Any])?["appointment_id"] as? String, "visit-1")
        XCTAssertEqual((manual["eventProperties"] as? [String: Any])?["clinic"] as? String, "sample")
        XCTAssertNil((identify["eventProperties"] as? [String: Any])?["clinic"])
    }
}
