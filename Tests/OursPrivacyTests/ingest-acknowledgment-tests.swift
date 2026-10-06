import XCTest
@testable import OursPrivacyKit

private final class ScriptedIngestRequest: FlushRequest, @unchecked Sendable {
    var responses: [IngestBatchResult?]
    private(set) var sentServerURLs: [String] = []
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    var holdFirst = false
    private var calls = 0

    required init(serverURL: String) {
        responses = []
        super.init(serverURL: serverURL)
    }

    convenience init(responses: [IngestBatchResult?]) {
        self.init(serverURL: BasePath.DefaultAPIEndpoint)
        self.responses = responses
    }

    override func sendRequest(_ requestData: String, type: FlushType,
                              headers: [String: String], queryItems: [URLQueryItem] = []) -> IngestBatchResult? {
        calls += 1
        sentServerURLs.append(serverURL)
        if holdFirst && calls == 1 {
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 5)
        }
        return responses.removeFirst()
    }
}

private final class RejectionCapture: @unchecked Sendable {
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

extension OursPrivacyTests {
    private func makeTask5Instance() -> OursPrivacy {
        OursPrivacy(token: "test-\(UUID().uuidString)", trackAutomaticEvents: false)
    }

    private func ingestResult(_ body: String) -> IngestBatchResult? {
        IngestBatchResult.parse(Data(body.utf8))
    }

    private func seedPersistedRejection(token: String) -> String {
        let persistence = OursPrivacyPersistence(instanceName: token)
        XCTAssertTrue(persistence.saveEntity([
            "event": "booking",
            "visitor_id": "visitor",
            "distinct_id": "persisted-event-id",
            "eventProperties": [:],
            "userProperties": NSNull(),
            "defaultProperties": [:]
        ], type: .events))
        return persistence.loadEntitiesInBatch(type: .events)
            .first?[OursPrivacyPersistence.localRowIDKey] as? String ?? ""
    }

    func testPersistedRejectionWaitsForInitializeCallbackAndServerURL() async {
        let token = "startup-rejection-\(UUID().uuidString)"
        let persistedRowID = seedPersistedRejection(token: token)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: token) }
        XCTAssertFalse(persistedRowID.isEmpty)
        let op = OursPrivacy(token: token, trackAutomaticEvents: false)
        let capture = RejectionCapture()
        let response = ingestResult("""
            {"success":true,"visitor_id":"visitor","accepted":0,
             "rejected":[{"index":0,"code":"mobile_occurred_at_future"}]}
            """)
        let request = ScriptedIngestRequest(responses: [response])
        op.flushInstance.flushRequest = request

        op.flushInterval = 10
        op.trackingQueue.sync {}
        op.networkQueue.sync {}
        XCTAssertTrue(request.sentServerURLs.isEmpty)
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .first?[OursPrivacyPersistence.localRowIDKey] as? String, persistedRowID)

        await op.initialize(options: OursPrivacyInitOptions(
            serverURL: "http://127.0.0.1:8765",
            onIngestRejected: { capture.append($0, $1) }))
        op.trackingQueue.sync {}
        op.trackingQueue.sync {}
        op.networkQueue.sync {}

        XCTAssertEqual(op.flushInterval, 10)
        XCTAssertEqual(request.sentServerURLs, ["http://127.0.0.1:8765"])
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        XCTAssertEqual(capture.captured.count, 1)
        XCTAssertEqual(capture.captured.first?.0, "persisted-event-id")
        XCTAssertEqual(capture.captured.first?.1, "mobile_occurred_at_future")
    }

    func testPersistedRejectionIsNotSentBeforeStartupOptOut() async {
        let token = "startup-optout-\(UUID().uuidString)"
        let persistedRowID = seedPersistedRejection(token: token)
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: token) }
        XCTAssertFalse(persistedRowID.isEmpty)
        let op = OursPrivacy(token: token, trackAutomaticEvents: false)
        let capture = RejectionCapture()
        let response = ingestResult("""
            {"success":true,"visitor_id":"visitor","accepted":0,
             "rejected":[{"index":0,"code":"mobile_occurred_at_future"}]}
            """)
        let request = ScriptedIngestRequest(responses: [response])
        op.flushInstance.flushRequest = request

        op.flushInterval = 10
        op.trackingQueue.sync {}
        op.networkQueue.sync {}
        XCTAssertTrue(request.sentServerURLs.isEmpty)

        await op.initialize(options: OursPrivacyInitOptions(
            optedOutByDefault: true,
            onIngestRejected: { capture.append($0, $1) }))
        op.trackingQueue.sync {}
        op.networkQueue.sync {}

        XCTAssertTrue(op.hasOptedOutTracking())
        XCTAssertTrue(request.sentServerURLs.isEmpty)
        XCTAssertTrue(capture.captured.isEmpty)
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    func testIndexedMixedBatchRemovesSentRowsAndReportsOnlyRejectedDistinctId() {
        let op = makeTask5Instance()
        op.flushBatchSize = 2
        let capture = RejectionCapture()
        op.onIngestRejected = { capture.append($0, $1) }
        for id in ["bad-event-id", "accepted-id", "later-id"] {
            op.track(event: "booking", properties: ["$distinct_id": id])
        }
        op.trackingQueue.sync {}
        let result = ingestResult("""
            {"success":true,"visitor_id":"visitor","accepted":1,
             "rejected":[{"index":0,"code":"mobile_occurred_at_future"}]}
            """)
        op.flushInstance.flushRequest = ScriptedIngestRequest(responses: [result])

        op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events, batchSize: 2), type: .events)

        XCTAssertEqual(capture.captured.count, 1)
        XCTAssertEqual(capture.captured.first?.0, "bad-event-id")
        XCTAssertEqual(capture.captured.first?.1, "mobile_occurred_at_future")
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .compactMap { $0["distinct_id"] as? String }, ["later-id"])
    }

    func testAllRejectedBatchReportsBothAfterDurableRemoval() {
        let op = makeTask5Instance()
        let capture = RejectionCapture()
        op.onIngestRejected = { id, code in
            XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
            capture.append(id, code)
        }
        for id in ["first", "second"] {
            op.track(event: "booking", properties: ["$distinct_id": id])
        }
        op.trackingQueue.sync {}
        let result = ingestResult("""
            {"success":true,"visitor_id":"visitor","accepted":0,
             "rejected":[{"index":0,"code":"bad_time"},{"index":1,"code":"bad_screen"}]}
            """)
        op.flushInstance.flushRequest = ScriptedIngestRequest(responses: [result])

        op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)

        XCTAssertEqual(capture.captured.map(\.0), ["first", "second"])
        XCTAssertEqual(capture.captured.map(\.1), ["bad_time", "bad_screen"])
    }

    func testFailedDurableRemovalRetainsBatchAndSuppressesRejection() {
        let op = makeTask5Instance()
        let capture = RejectionCapture()
        op.onIngestRejected = { capture.append($0, $1) }
        op.track(event: "booking", properties: ["$distinct_id": "first"])
        op.trackingQueue.sync {}
        let result = ingestResult("""
            {"success":true,"visitor_id":"visitor","accepted":0,
             "rejected":[{"index":0,"code":"bad_time"}]}
            """)
        op.flushInstance.flushRequest = ScriptedIngestRequest(responses: [result])
        op.oursprivacyPersistence.persistenceWrite = { _ in false }

        op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)

        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 1)
        XCTAssertTrue(capture.captured.isEmpty)
    }

    func testNetworkFailureRetainsQueuedBatch() {
        let op = makeTask5Instance()
        let capture = RejectionCapture()
        op.onIngestRejected = { capture.append($0, $1) }
        op.track(event: "booking")
        op.track(event: "second-booking")
        op.trackingQueue.sync {}
        op.flushInstance.flushRequest = ScriptedIngestRequest(responses: [nil])

        op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)

        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 2)
        XCTAssertTrue(capture.captured.isEmpty)
    }

    func testInvalidResponsesNeverAcknowledgeOrReportRejection() {
        let invalid = [
            #"{"success":false,"visitor_id":"visitor","accepted":1,"rejected":[]}"#,
            #"{"success":true,"visitor_id":"visitor","accepted":1}"#,
            #"{"success":true,"visitor_id":"visitor","rejected":[]}"#,
            #"{"success":true,"visitor_id":"visitor","accepted":0,"rejected":[]}"#,
            #"{"success":true,"visitor_id":"visitor","accepted":0,"rejected":[{"index":0,"code":"bad"},{"index":0,"code":"bad"}]}"#,
            #"{"success":true,"visitor_id":"visitor","accepted":0,"rejected":[{"index":1,"code":"bad"}]}"#,
            #"{"success":true}"#,
            #"{"success":true,"visitor_id":"visitor","accepted":true,"rejected":[]}"#,
            #"{"success":true,"visitor_id":"visitor","accepted":0,"rejected":[{"index":0}]}"#,
            #"{"success":true,"visitor_id":"visitor","accepted":0,"rejected":[{"index":-1,"code":"bad"}]}"#,
            #"{"success":true,"visitor_id":"visitor","accepted":null,"rejected":null}"#,
            #"not-json"#
        ]
        for body in invalid {
            let op = makeTask5Instance()
            let capture = RejectionCapture()
            op.onIngestRejected = { capture.append($0, $1) }
            op.track(event: "booking")
            op.trackingQueue.sync {}
            op.flushInstance.flushRequest = ScriptedIngestRequest(responses: [ingestResult(body)])
            op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
            XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 1, body)
            XCTAssertTrue(capture.captured.isEmpty, body)
        }
    }

    func testLegacyResponseAcknowledgesBeforeIndexedMode() {
        let op = makeTask5Instance()
        op.track(event: "booking")
        op.trackingQueue.sync {}
        op.flushInstance.flushRequest = ScriptedIngestRequest(
            responses: [ingestResult(#"{"success":true,"visitor_id":"visitor"}"#)])
        op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    func testIndexedModePersistsAcrossRestartAndRejectsLegacyFallback() {
        let token = "indexed-\(UUID().uuidString)"
        let original = OursPrivacy(token: token, trackAutomaticEvents: false)
        original.track(event: "first")
        original.trackingQueue.sync {}
        original.flushInstance.flushRequest = ScriptedIngestRequest(responses: [
            ingestResult(#"{"success":true,"visitor_id":"visitor","accepted":1,"rejected":[]}"#)
        ])
        original.flushQueue(original.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
        XCTAssertTrue(original.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        let restarted = OursPrivacy(token: token, trackAutomaticEvents: false)
        restarted.track(event: "second")
        restarted.trackingQueue.sync {}
        restarted.flushInstance.flushRequest = ScriptedIngestRequest(
            responses: [ingestResult(#"{"success":true,"visitor_id":"visitor"}"#)])
        restarted.flushQueue(restarted.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
        XCTAssertEqual(restarted.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, 1)
        OursPrivacyPersistence.deleteUserDefaultsData(instanceName: token)
    }

    func testIndexedModeSurvivesResetAndOptOutAcrossRestart() {
        for privacyAction in ["reset", "opt-out"] {
            let token = "indexed-\(privacyAction)-\(UUID().uuidString)"
            defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: token) }
            let original = OursPrivacy(token: token, trackAutomaticEvents: false)
            original.track(event: "first")
            original.trackingQueue.sync {}
            original.flushInstance.flushRequest = ScriptedIngestRequest(responses: [
                ingestResult(#"{"success":true,"visitor_id":"visitor","accepted":1,"rejected":[]}"#)
            ])
            original.flushQueue(original.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)
            XCTAssertTrue(original.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

            if privacyAction == "reset" {
                original.reset()
            } else {
                original.optOutTracking()
            }
            original.trackingQueue.sync {}

            let restarted = OursPrivacy(token: token, trackAutomaticEvents: false)
            if privacyAction == "opt-out" {
                restarted.optInTracking()
            }
            restarted.track(event: "second")
            restarted.trackingQueue.sync {}
            let pending = restarted.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            XCTAssertTrue(pending.contains { $0["event"] as? String == "second" })
            restarted.flushInstance.flushRequest = ScriptedIngestRequest(
                responses: [ingestResult(#"{"success":true,"visitor_id":"visitor"}"#)])
            restarted.flushQueue(pending, type: .events)
            XCTAssertEqual(restarted.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count,
                           pending.count, privacyAction)
        }
    }

    func testStaleIndexedResponseCannotRemoveSameNumericIdAndDistinctIdAfterReset() {
        let op = makeTask5Instance()
        let capture = RejectionCapture()
        op.onIngestRejected = { capture.append($0, $1) }
        op.track(event: "old", properties: ["$distinct_id": "reused"])
        op.trackingQueue.sync {}
        let old = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let result = ingestResult("""
            {"success":true,"visitor_id":"visitor","accepted":0,
             "rejected":[{"index":0,"code":"bad_time"}]}
            """)
        let request = ScriptedIngestRequest(responses: [result])
        request.holdFirst = true
        op.flushInstance.flushRequest = request
        op.flush(performFullFlush: true)
        XCTAssertEqual(request.firstStarted.wait(timeout: .now() + 2), .success)
        op.reset()
        op.trackingQueue.sync {}
        op.track(event: "new", properties: ["$distinct_id": "reused"])
        op.trackingQueue.sync {}
        let replacement = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(replacement.first?["id"] as? Int32, old.first?["id"] as? Int32)
        XCTAssertNotEqual(replacement.first?["op_local_row_id"] as? String,
                          old.first?["op_local_row_id"] as? String)

        request.releaseFirst.signal()
        op.networkQueue.sync {}

        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .first?["event"] as? String, "new")
        XCTAssertTrue(capture.captured.isEmpty)
    }

}
