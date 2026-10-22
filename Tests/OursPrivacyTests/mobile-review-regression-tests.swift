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
