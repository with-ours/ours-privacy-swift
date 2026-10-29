import Foundation
import XCTest
@testable import OursPrivacyKit

final class OfflineIngestRequest: FlushRequest, @unchecked Sendable {
    override func sendRequest(_ requestData: String, type: FlushType,
                              headers: [String: String], queryItems: [URLQueryItem] = [],
                              generation: UInt64) -> IngestBatchResult? {
        nil
    }
}

extension OursPrivacyTests {
    func testResetFlushPreservesCapturedModeAndSendsAuthoritativeNewIdentity() async throws {
        for originalManualMode in [false, true] {
            let op = makeMobileInstance(name: "reset-flush-\(UUID().uuidString)")
            defer {
                op.flushInterval = 0
                OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name)
                UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)?
                    .removeObject(forKey: "oursprivacy-\(op.name)-OPMobileSession")
            }
            op.flushInterval = 0
            if originalManualMode { op.setVisitorId("linked-before-reset") }
            await op.initialize()
            let originalVisitor = op.visitorId
            let origin = Int64(Date().timeIntervalSince1970 * 1_000)
            op.mobileQueueNowMs = { origin + 70_000 }
            op.captureMobileTime = { MobileTimePoint(epochMs: origin + 10_000, monotonicMs: 10_000) }
            op.mobileForeground(at: MobileTimePoint(epochMs: origin, monotonicMs: 0))
            op.track(event: "before-reset")
            op.reset()
            op.track(event: "after-reset")
            op.mobileBackground(at: MobileTimePoint(epochMs: origin + 70_000, monotonicMs: 70_000))
            op.trackingQueue.sync {}
            let resetVisitor = op.visitorId
            XCTAssertNotEqual(resetVisitor, originalVisitor)

            let request = RecordingFlushRequest(serverURL: op.serverURL)
            op.flushInstance.flushRequest = request
            op.flush(performFullFlush: true)
            op.trackingQueue.sync {}
            op.networkQueue.sync {}
            let envelopes = try request.sentBodies.map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? InternalProperties)
            }
            XCTAssertEqual(envelopes.count, 2)
            guard envelopes.count == 2 else { continue }
            let oldItems = try XCTUnwrap(envelopes[0]["data"] as? [InternalProperties])
            let newItems = try XCTUnwrap(envelopes[1]["data"] as? [InternalProperties])
            XCTAssertEqual(envelopes[0]["is_manually_set_id"] as? Bool, originalManualMode)
            XCTAssertEqual(envelopes[1]["is_manually_set_id"] as? Bool, true)
            XCTAssertEqual(Set(oldItems.compactMap { $0["visitor_id"] as? String }), [originalVisitor])
            XCTAssertEqual(Set(newItems.compactMap { $0["visitor_id"] as? String }), [resetVisitor])
            XCTAssertTrue(oldItems.contains { $0["event"] as? String == "before-reset" })
            XCTAssertTrue(oldItems.contains { $0["event"] as? String == "$mobile_session_end" })
            XCTAssertEqual(newItems.compactMap { $0["event"] as? String },
                           ["$mobile_session_start", "after-reset", "$mobile_session_engagement"])
            let engagementProperties = try XCTUnwrap(newItems.last?["eventProperties"] as? InternalProperties)
            XCTAssertEqual(engagementProperties["engagement_duration_ms"] as? Int64, 60_000)
            XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        }
    }

    func testResetIdentityAndCapturedModesSurviveRecreation() throws {
        let token = "reset-recreation-\(UUID().uuidString)"
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: token) }
        let original = OursPrivacy(token: token, trackAutomaticEvents: false)
        let originalVisitor = original.visitorId
        original.track(event: "before-reset")
        original.reset()
        original.track(event: "after-reset")
        original.trackingQueue.sync {}
        let resetVisitor = original.visitorId
        XCTAssertNotEqual(resetVisitor, originalVisitor)

        let recreated = OursPrivacy(token: token, trackAutomaticEvents: false)
        XCTAssertEqual(recreated.visitorId, resetVisitor)
        XCTAssertTrue(recreated.isManuallySetId)
        recreated.track(event: "after-recreation")
        recreated.trackingQueue.sync {}
        let request = RecordingFlushRequest(serverURL: recreated.serverURL)
        recreated.flushInstance.flushRequest = request
        recreated.flush(performFullFlush: true)
        recreated.trackingQueue.sync {}
        recreated.networkQueue.sync {}
        let envelopes = try request.sentBodies.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? InternalProperties)
        }
        XCTAssertEqual(envelopes.count, 2)
        guard envelopes.count == 2 else { return }
        let oldItems = try XCTUnwrap(envelopes[0]["data"] as? [InternalProperties])
        let resetItems = try XCTUnwrap(envelopes[1]["data"] as? [InternalProperties])
        XCTAssertEqual(envelopes[0]["is_manually_set_id"] as? Bool, false)
        XCTAssertEqual(envelopes[1]["is_manually_set_id"] as? Bool, true)
        XCTAssertEqual(oldItems.compactMap { $0["event"] as? String }, ["before-reset"])
        XCTAssertEqual(oldItems.compactMap { $0["visitor_id"] as? String }, [originalVisitor])
        XCTAssertEqual(resetItems.compactMap { $0["event"] as? String }, ["after-reset", "after-recreation"])
        XCTAssertEqual(resetItems.compactMap { $0["visitor_id"] as? String }, [resetVisitor, resetVisitor])
        XCTAssertTrue(recreated.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    func testSetVisitorIdFlipsManuallySetFlag() {
        let op = OursPrivacy(token: "identity-setter-\(UUID().uuidString)", trackAutomaticEvents: false)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
        XCTAssertFalse(op.isManuallySetId)
        op.setVisitorId("stitched-from-web-123")
        XCTAssertEqual(op.getVisitorId(), "stitched-from-web-123")
        XCTAssertTrue(op.isManuallySetId)
        op.trackingQueue.sync {}
    }

    func testResetRetainsOfflineEventsWithCapturedIdentityAndClearsFutureProperties() {
        let op = OursPrivacy(token: "reset-retention-\(UUID().uuidString)", trackAutomaticEvents: false)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
        let originalVisitor = op.visitorId
        op.updateDefaultEventProperties(["account_state": "before"])
        op.track(event: "Logged Out")
        op.reset()
        op.track(event: "Welcome")
        op.trackingQueue.sync {}

        let restarted = OursPrivacyPersistence(instanceName: op.name)
        let events = restarted.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String }, ["Logged Out", "Welcome"])
        XCTAssertEqual(events.first?["visitor_id"] as? String, originalVisitor)
        XCTAssertEqual(events.last?["visitor_id"] as? String, op.visitorId)
        XCTAssertNotEqual(op.visitorId, originalVisitor)
        XCTAssertEqual((events.first?["eventProperties"] as? InternalProperties)?["account_state"] as? String, "before")
        XCTAssertNil((events.last?["eventProperties"] as? InternalProperties)?["account_state"])

        op.optOutTracking()
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    func testFailedDirectTrackAndIdentifyWritesRetainCapturedEventsUntilStorageRecovers() async {
        let op = OursPrivacy(token: "direct-write-retry-\(UUID().uuidString)", trackAutomaticEvents: false)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
        op.mobilePendingRetryIntervalMs = 60_000
        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        let completed = expectation(description: "identify persisted")
        op.track(event: "offline")
        op.identify(OursPrivacyUserProperties(externalId: "account-1")) { completed.fulfill() }
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        op.reset()
        op.trackingQueue.sync {}
        op.oursprivacyPersistence.persistenceWrite = persist
        op.track(event: "recovered")
        op.trackingQueue.sync {}
        await fulfillment(of: [completed], timeout: 2)
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.compactMap { $0["event"] as? String }, ["offline", "$identify", "recovered"])
        guard events.count == 3 else { return }
        XCTAssertEqual(events.first?["visitor_id"] as? String, events[1]["visitor_id"] as? String)
        XCTAssertNotEqual(events.first?["visitor_id"] as? String, events.last?["visitor_id"] as? String)
    }

    func testFreshInstallQueuesFirstOpenWhenLegacyRuntimeMarksInstallAfterConstruction() async {
        let name = "fresh-runtime-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)
        let oldGlobal = defaults?.object(forKey: "OPFirstOpen")
        defaults?.removeObject(forKey: "OPFirstOpen")
        defer {
            defaults?.set(oldGlobal, forKey: "OPFirstOpen")
            defaults?.removeObject(forKey: "OPFirstOpen-\(name)")
            defaults?.removeObject(forKey: "oursprivacy-\(name)-OPMobileSession")
            OursPrivacyPersistence.deleteUserDefaultsData(instanceName: name)
        }
        let op = makeMobileInstance(name: name)
        #if !os(iOS) && !os(tvOS) && !os(visionOS)
        defaults?.set(true, forKey: "OPFirstOpen-\(name)")
        #endif
        await op.initialize()
        op.mobileForeground(at: MobileTimePoint.capture())
        op.trackingQueue.sync {}
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(events.filter { $0["event"] as? String == "$mobile_first_open" }.count, 1)
        XCTAssertTrue(op.mobileSession?.hasAcceptedFirstOpen ?? false)
        XCTAssertTrue(defaults?.bool(forKey: "OPFirstOpen-\(name)") ?? false)
    }
}
