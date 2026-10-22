import Foundation
import XCTest
@testable import OursPrivacyKit

private final class ReviewIngestProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sdk-ingest-review.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let route = url.pathComponents.dropFirst().first ?? ""
        let status = route == "forbidden" ? 403 : 200
        let body: String
        switch route {
        case "html": body = "<html>Please sign in to Wi-Fi</html>"
        case "broken": body = #"{"success":true"#
        case "array": body = #"[]"#
        case "string": body = #""accepted""#
        case "null": body = "null"
        case "number": body = "1"
        case "bool": body = "true"
        case "whitespace": body = " \n\t"
        case "extra": body = #"{"proxy_request_id":"request"}"#
        default: body = ""
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class NetworkReviewRejections: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, String)] = []

    func append(_ id: String, _ code: String) {
        lock.lock()
        values.append((id, code))
        lock.unlock()
    }

    var captured: [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class IngestNetworkReviewTests: XCTestCase {
    func testRepeatedHTTP403RetainsOfflineRowsBeyondMalformedLimitAndUploadsAfterRecovery() {
        XCTAssertTrue(URLProtocol.registerClass(ReviewIngestProtocol.self))
        defer { URLProtocol.unregisterClass(ReviewIngestProtocol.self) }
        let op = OursPrivacy(token: "http-forbidden-\(UUID().uuidString)", trackAutomaticEvents: false)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
        op.serverURL = "https://sdk-ingest-review.test/forbidden"
        let capture = NetworkReviewRejections()
        op.onIngestRejected = { capture.append($0, $1) }
        op.track(event: "offline", properties: ["$distinct_id": "offline-id"])
        op.track(event: "following", properties: ["$distinct_id": "following-id"])
        op.trackingQueue.sync {}
        let original = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)

        for _ in 0 ..< 6 {
            op.flushInstance.flushRequest.networkRequestsAllowedAfterTime = 0
            op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
            let persisted = OursPrivacyPersistence(instanceName: op.name).loadEntitiesInBatch(type: .events)
            XCTAssertEqual(persisted as NSArray, original as NSArray)
            XCTAssertTrue(capture.captured.isEmpty)
        }

        op.serverURL = "https://sdk-ingest-review.test/extra"
        op.flushInstance.flushRequest.networkRequestsAllowedAfterTime = 0
        op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
        XCTAssertTrue(OursPrivacyPersistence(instanceName: op.name).loadEntitiesInBatch(type: .events).isEmpty)
        XCTAssertTrue(capture.captured.isEmpty)
    }

    func testNonemptyNonobjectHTTPBodiesRetainHeadFourTimesThenRejectDurably() {
        XCTAssertTrue(URLProtocol.registerClass(ReviewIngestProtocol.self))
        defer { URLProtocol.unregisterClass(ReviewIngestProtocol.self) }
        for route in ["html", "broken", "array", "string", "null", "number", "bool", "whitespace"] {
            let op = OursPrivacy(token: "http-review-\(UUID().uuidString)", trackAutomaticEvents: false)
            defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
            op.serverURL = "https://sdk-ingest-review.test/\(route)"
            op.flushBatchSize = 1
            let capture = NetworkReviewRejections()
            op.onIngestRejected = { id, code in
                let persisted = OursPrivacyPersistence(instanceName: op.name).loadEntitiesInBatch(type: .events)
                XCTAssertEqual(persisted.compactMap { $0["distinct_id"] as? String }, ["following-id"], route)
                capture.append(id, code)
            }
            op.track(event: "offline", properties: ["$distinct_id": "offline-id"])
            op.track(event: "following", properties: ["$distinct_id": "following-id"])
            op.trackingQueue.sync {}
            let original = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            for _ in 0 ..< 4 {
                op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
                XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events) as NSArray,
                               original as NSArray, route)
                XCTAssertTrue(capture.captured.isEmpty, route)
            }

            op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)

            XCTAssertEqual(capture.captured.map(\.0), ["offline-id"], route)
            XCTAssertEqual(capture.captured.map(\.1), ["invalid_acknowledgment"], route)
            XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
                .compactMap { $0["distinct_id"] as? String }, ["following-id"], route)
            op.serverURL = "https://sdk-ingest-review.test/extra"
            op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
            XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty, route)
            XCTAssertEqual(capture.captured.count, 1, route)
        }
    }
}
