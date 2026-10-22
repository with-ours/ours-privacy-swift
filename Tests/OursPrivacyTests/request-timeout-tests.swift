import Foundation
import XCTest
@testable import OursPrivacyKit

private final class TimedOutIngestProtocol: URLProtocol {
    static let started = DispatchSemaphore(value: 0)
    static let stopped = DispatchSemaphore(value: 0)

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sdk-timeout.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() { Self.started.signal() }
    override func stopLoading() { Self.stopped.signal() }
}

final class RequestTimeoutTests: XCTestCase {
    func testTimedOutUploadIsCanceledAndRetainsOfflineRowsWithoutRejection() {
        XCTAssertTrue(URLProtocol.registerClass(TimedOutIngestProtocol.self))
        defer { URLProtocol.unregisterClass(TimedOutIngestProtocol.self) }
        let op = OursPrivacy(token: "timeout-\(UUID().uuidString)", trackAutomaticEvents: false)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
        op.serverURL = "https://sdk-timeout.test"
        op.flushInstance.flushRequest.requestCompletionTimeout = 0.1
        let rejected = DispatchSemaphore(value: 0)
        op.onIngestRejected = { _, _ in rejected.signal() }
        op.track(event: "offline")
        op.trackingQueue.sync {}
        let original = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)

        op.flushQueue(original, type: .events)

        XCTAssertEqual(TimedOutIngestProtocol.started.wait(timeout: .now() + 2), .success)
        let stopped = TimedOutIngestProtocol.stopped.wait(timeout: .now() + 2)
        XCTAssertEqual(OursPrivacyPersistence(instanceName: op.name).loadEntitiesInBatch(type: .events) as NSArray,
                       original as NSArray)
        op.optOutTracking()
        op.trackingQueue.sync {}
        XCTAssertEqual(stopped, .success)
        XCTAssertEqual(rejected.wait(timeout: .now()), .timedOut)
        let persisted = OursPrivacyPersistence(instanceName: op.name)
        XCTAssertTrue(persisted.loadEntitiesInBatch(type: .events).isEmpty)
    }
}
