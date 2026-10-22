import Foundation
import XCTest
@testable import OursPrivacyKit

private class HeldIngestProtocol: URLProtocol {
    static let started = DispatchSemaphore(value: 0)
    static let stopped = DispatchSemaphore(value: 0)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sdk-opt-out.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() { Self.started.signal() }

    override func stopLoading() { Self.stopped.signal() }
}

private final class PausedFlushRequest: FlushRequest, @unchecked Sendable {
    let reachedSend = DispatchSemaphore(value: 0)
    let releaseSend = DispatchSemaphore(value: 0)

    override func sendRequest(_ requestData: String, type: FlushType,
                              headers: [String: String], queryItems: [URLQueryItem] = [],
                              generation: UInt64) -> IngestBatchResult? {
        reachedSend.signal()
        _ = releaseSend.wait(timeout: .now() + 5)
        return super.sendRequest(requestData, type: type, headers: headers,
                                 queryItems: queryItems, generation: generation)
    }
}

private final class HeldRejectionRequest: FlushRequest, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    override func sendRequest(_ requestData: String, type: FlushType,
                              headers: [String: String], queryItems: [URLQueryItem] = [],
                              generation: UInt64) -> IngestBatchResult? {
        started.signal()
        _ = release.wait(timeout: .now() + 5)
        return IngestBatchResult.parse(Data(#"{"success":false}"#.utf8))
    }
}

final class FlushOptOutTests: XCTestCase {
    func testOptOutCancelsActiveNetworkTask() {
        XCTAssertTrue(URLProtocol.registerClass(HeldIngestProtocol.self))
        defer { URLProtocol.unregisterClass(HeldIngestProtocol.self) }
        let op = OursPrivacy(token: "test-\(UUID().uuidString)", trackAutomaticEvents: false)
        op.serverURL = "https://sdk-opt-out.test"
        op.track(event: "queued-event")
        op.trackingQueue.sync {}

        op.flush(performFullFlush: true)
        guard HeldIngestProtocol.started.wait(timeout: .now() + 2) == .success else {
            XCTFail("The test request did not start")
            return
        }
        op.trackingQueue.suspend()
        op.optOutTracking()
        XCTAssertTrue(op.hasOptedOutTracking())
        let stopped = HeldIngestProtocol.stopped.wait(timeout: .now() + 2)
        op.trackingQueue.resume()
        XCTAssertEqual(stopped, .success)
        op.trackingQueue.sync {}
        let finished = DispatchSemaphore(value: 0)
        op.networkQueue.async { finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }

    func testOptOutSuppressesActiveRejectionBeforeBlockedTrackingQueueCanClearStorage() {
        let op = OursPrivacy(token: "opt-out-rejection-\(UUID().uuidString)", trackAutomaticEvents: false)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
        op.track(event: "queued")
        op.trackingQueue.sync {}
        let request = HeldRejectionRequest(serverURL: op.serverURL)
        op.flushInstance.flushRequest = request
        let rejected = DispatchSemaphore(value: 0)
        op.onIngestRejected = { _, _ in rejected.signal() }
        op.flush(performFullFlush: true)
        XCTAssertEqual(request.started.wait(timeout: .now() + 2), .success)

        op.trackingQueue.suspend()
        op.optOutTracking()
        XCTAssertTrue(op.hasOptedOutTracking())
        request.release.signal()
        op.networkQueue.sync {}
        XCTAssertEqual(rejected.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 1)
        op.trackingQueue.resume()
        op.trackingQueue.sync {}
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    func testOlderQueuedOptInCannotReopenTrackingAfterNewerPublicOptOut() {
        let op = OursPrivacy(token: "consent-order-\(UUID().uuidString)", trackAutomaticEvents: false)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        op.trackingQueue.suspend()
        op.optInTracking()
        op.trackingQueue.async {
            reached.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        op.optOutTracking()
        op.trackingQueue.resume()
        XCTAssertEqual(reached.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(op.hasOptedOutTracking())
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        release.signal()
        op.trackingQueue.sync {}
    }

    func testOptOutBetweenRowCheckAndSendRejectsStaleBatchAfterOptIn() {
        XCTAssertTrue(URLProtocol.registerClass(HeldIngestProtocol.self))
        defer { URLProtocol.unregisterClass(HeldIngestProtocol.self) }
        let op = OursPrivacy(token: "test-\(UUID().uuidString)", trackAutomaticEvents: false)
        op.serverURL = "https://sdk-opt-out.test"
        op.track(event: "queued-event")
        op.trackingQueue.sync {}
        let request = PausedFlushRequest(serverURL: op.serverURL)
        op.flushInstance.flushRequest = request

        op.flush(performFullFlush: true)
        guard request.reachedSend.wait(timeout: .now() + 2) == .success else {
            XCTFail("The test request did not reach send")
            return
        }
        op.optOutTracking()
        op.trackingQueue.sync {}
        op.optInTracking()
        op.trackingQueue.sync {}
        request.releaseSend.signal()

        let sent = HeldIngestProtocol.started.wait(timeout: .now() + 1)
        op.optOutTracking()
        op.trackingQueue.sync {}
        let finished = DispatchSemaphore(value: 0)
        op.networkQueue.async { finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(sent, .timedOut)
    }

    func testOptOutDoesNotRetryActiveFailureOrSendOldRowsAfterOptIn() {
        let op = OursPrivacy(token: "test-\(UUID().uuidString)", trackAutomaticEvents: false)
        op.flushBatchSize = 1
        op.track(event: "old-first")
        op.track(event: "old-second")
        op.trackingQueue.sync {}
        let old = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let request = HeldFirstFlushRequest(serverURL: op.serverURL)
        request.failFirst = true
        op.flushInstance.flushRequest = request

        op.flush(performFullFlush: true)
        XCTAssertEqual(request.firstStarted.wait(timeout: .now() + 2), .success)
        op.optOutTracking()
        op.trackingQueue.sync {}
        op.flush(performFullFlush: true)
        request.releaseFirst.signal()
        op.networkQueue.sync {}
        XCTAssertEqual(request.sentBodies.count, 1)
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        op.optInTracking()
        op.track(event: "new-event")
        op.trackingQueue.sync {}
        op.flushQueue(old, type: .events)
        op.flush(performFullFlush: true)
        op.trackingQueue.sync {}
        op.networkQueue.sync {}
        XCTAssertTrue(request.sentBodies.dropFirst().joined().contains("new-event"))
        XCTAssertFalse(request.sentBodies.dropFirst().joined().contains("old-first"))
        XCTAssertFalse(request.sentBodies.dropFirst().joined().contains("old-second"))
    }

}
