import Foundation
import XCTest
@testable import OursPrivacyKit

private class IngestResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sdk-ingest-contract.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let route = url.pathComponents.dropFirst().first ?? ""
        let status = Int(route) ?? 200
        let body: String
        switch route {
        case "rejected": body = #"{"success":false}"#
        case "retryable": body = #"{"success":false,"retryable":true}"#
        case "extra": body = #"{"success":true,"request_id":"request"}"#
        default: body = ""
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class HTTPRejectionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ code: String) {
        lock.lock()
        values.append(code)
        lock.unlock()
    }

    var codes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class IngestHTTPResponseTests: XCTestCase {
    func testHTTPResponseContractAcknowledgesSuccessRejectsPermanentAndRetainsRetryable() {
        XCTAssertTrue(URLProtocol.registerClass(IngestResponseProtocol.self))
        defer { URLProtocol.unregisterClass(IngestResponseProtocol.self) }
        let cases: [(String, Bool, [String])] = [
            ("200", true, []), ("201", true, []), ("204", true, []), ("extra", true, []),
            ("rejected", true, ["ingest_rejected"]), ("retryable", false, []),
            ("400", true, ["http_400"]), ("401", true, ["http_401"]),
            ("403", false, []), ("404", true, ["http_404"]),
            ("410", true, ["http_410"]), ("422", true, ["http_422"]),
            ("408", false, []), ("425", false, []), ("429", false, []),
            ("500", false, []), ("503", false, [])
        ]
        for (route, removed, codes) in cases {
            let op = OursPrivacy(token: "http-contract-\(UUID().uuidString)", trackAutomaticEvents: false)
            defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
            op.serverURL = "https://sdk-ingest-contract.test/\(route)"
            let capture = HTTPRejectionCapture()
            op.onIngestRejected = { _, code in
                XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
                capture.append(code)
            }
            op.track(event: "booking", properties: ["$distinct_id": "booking-id"])
            op.trackingQueue.sync {}
            op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)

            XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty, removed, route)
            XCTAssertEqual(capture.codes, codes, route)
        }
    }

    func testPermanentHTTPRejectionDoesNotNotifyBeforeQueueRemovalSucceeds() {
        XCTAssertTrue(URLProtocol.registerClass(IngestResponseProtocol.self))
        defer { URLProtocol.unregisterClass(IngestResponseProtocol.self) }
        let op = OursPrivacy(token: "http-storage-\(UUID().uuidString)", trackAutomaticEvents: false)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name) }
        op.serverURL = "https://sdk-ingest-contract.test/422"
        let capture = HTTPRejectionCapture()
        op.onIngestRejected = { _, code in capture.append(code) }
        op.track(event: "booking")
        op.trackingQueue.sync {}
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 1)
        XCTAssertTrue(capture.codes.isEmpty)
    }
}
