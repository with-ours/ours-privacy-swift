import XCTest
@testable import OursPrivacyKit

private final class ScriptedIngestRequest: FlushRequest, @unchecked Sendable {
    var responses: [IngestBatchResult?]
    private(set) var sentServerURLs: [String] = []
    private(set) var sentEnvelopes: [InternalProperties] = []
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    var holdFirst = false
    var enforcePropertyCapacity = false
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
                              headers: [String: String], queryItems: [URLQueryItem] = [],
                              generation: UInt64) -> IngestBatchResult? {
        calls += 1
        sentServerURLs.append(serverURL)
        if let data = requestData.data(using: .utf8),
           let envelope = try? JSONSerialization.jsonObject(with: data) as? InternalProperties {
            sentEnvelopes.append(envelope)
            if enforcePropertyCapacity, (envelope["data"] as? Queue ?? []).contains(where: {
                guard let properties = $0["eventProperties"] as? InternalProperties else { return false }
                guard let encoded = JSONHandler.encodeAPIData(properties) else { return true }
                return properties.count > 200 || encoded.utf16.count >= 1_048_576
            }) { return nil }
        }
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
    func testCallerBagNearSerializedSizeLimitAndFollowingEventBothUpload() async throws {
        let op = makeMobileInstance()
        op.flushInstance.delegate = nil
        op.trackAutomaticEventsEnabled = false
        await op.initialize()
        let ordinary = ["field": String(repeating: "a", count: 1_048_563)]
        XCTAssertEqual(try XCTUnwrap(JSONHandler.encodeAPIData(ordinary)).utf16.count, 1_048_575)
        op.track(event: "large-booking", properties: ordinary.mapValues { $0 as OursPrivacyType })
        op.track(event: "following-booking", properties: ["appointment_id": "visit-1"])
        op.trackingQueue.sync {}
        let success = ingestResult(#"{"success":true,"visitor_id":"visitor"}"#)
        let request = ScriptedIngestRequest(responses: [success, success])
        request.enforcePropertyCapacity = true
        op.flushInstance.flushBatchSize = 1
        op.flushInstance.flushRequest = request
        op.flushInstance.delegate = op

        op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)

        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        let uploaded = request.sentEnvelopes.flatMap { $0["data"] as? Queue ?? [] }
        XCTAssertEqual(uploaded.compactMap { $0["event"] as? String }, ["large-booking", "following-booking"])
        let properties = try XCTUnwrap(uploaded.first?["eventProperties"] as? InternalProperties)
        XCTAssertTrue(properties as NSDictionary == ordinary as NSDictionary)
        XCTAssertEqual(try XCTUnwrap(JSONHandler.encodeAPIData(properties)).utf16.count, 1_048_575)
        XCTAssertNotNil((uploaded.first?["defaultProperties"] as? InternalProperties)?["sid"] as? String)
        XCTAssertEqual((uploaded.last?["eventProperties"] as? InternalProperties)?["mobile_contract_version"] as? Int, 1)
        XCTAssertEqual((uploaded.last?["eventProperties"] as? InternalProperties)?["appointment_id"] as? String, "visit-1")
    }

    func testTwoHundredCallerPropertiesAndFollowingEventBothUpload() async throws {
        let op = makeMobileInstance()
        op.flushInstance.delegate = nil
        op.trackAutomaticEventsEnabled = false
        await op.initialize()
        let ordinary = Dictionary(uniqueKeysWithValues: (0 ..< 200).map { ("field_\($0)", "value_\($0)") })
        op.track(event: "large-booking", properties: ordinary.mapValues { $0 as OursPrivacyType })
        op.track(event: "following-booking", properties: ["appointment_id": "visit-1"])
        op.trackingQueue.sync {}
        let request = ScriptedIngestRequest(responses: [ingestResult(#"{"success":true,"visitor_id":"visitor"}"#)])
        request.enforcePropertyCapacity = true
        op.flushInstance.flushRequest = request
        op.flushInstance.delegate = op

        op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)

        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        let batch = try XCTUnwrap(request.sentEnvelopes.first?["data"] as? Queue)
        XCTAssertEqual(batch.compactMap { $0["event"] as? String }, ["large-booking", "following-booking"])
        XCTAssertEqual((batch.first?["eventProperties"] as? NSDictionary), ordinary as NSDictionary)
        XCTAssertNotNil((batch.first?["defaultProperties"] as? InternalProperties)?["sid"] as? String)
        XCTAssertEqual((batch.last?["eventProperties"] as? InternalProperties)?["mobile_contract_version"] as? Int, 1)
        XCTAssertEqual((batch.last?["eventProperties"] as? InternalProperties)?["appointment_id"] as? String, "visit-1")
    }

    func testSameVisitorModeChangeSettlesOldEngagementAndPersistsNewMode() async throws {
        let op = makeMobileInstance()
        op.flushInstance.delegate = nil
        await op.initialize()
        let start = mobilePoint()
        op.mobileQueueNowMs = { start.epochMs + 30_000 }
        op.mobileForeground(at: start)
        op.trackingQueue.sync {}
        let visitor = try XCTUnwrap(op.getVisitorId())
        let original = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let sid = try XCTUnwrap((original.first?["defaultProperties"] as? InternalProperties)?["sid"] as? String)
        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.captureMobileTime = {
            MobileTimePoint(epochMs: start.epochMs + 5_000, monotonicMs: start.monotonicMs + 5_000)
        }

        op.setVisitorId(visitor)

        let manual = op.currentEventContext(at: op.captureMobileTime())
        XCTAssertEqual(manual.isManuallySetId, true)
        XCTAssertEqual(manual.mobileSnapshot?.sid, sid)
        let settled = try XCTUnwrap(op.mobileSession?.pendingFacts.first { $0.name == "$mobile_session_engagement" })
        XCTAssertEqual(settled.isManuallySetId, false)
        XCTAssertEqual(settled.properties["engagement_duration_ms"] as? Int64, 5_000)
        let later = op.trackingQueue.sync {
            [10_000, 20_000].flatMap { elapsed in
                op.mobileSession?.checkpoint(at: MobileTimePoint(
                    epochMs: start.epochMs + Int64(elapsed), monotonicMs: start.monotonicMs + Int64(elapsed))) ?? []
            }
        }
        XCTAssertEqual(later.map(\.isManuallySetId), [true, true])
        XCTAssertEqual(later.compactMap { $0.properties["engagement_duration_ms"] as? Int64 }, [5_000, 10_000])
        XCTAssertTrue(later.allSatisfy { $0.sid == sid && $0.visitorId == visitor })
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events) as NSArray, original as NSArray)
        op.setVisitorId(visitor)
        XCTAssertEqual(op.mobileSession?.pendingFacts.count, 3)
        op.oursprivacyPersistence.persistenceWrite = persist
        op.track(event: "after-mode-change")
        op.trackingQueue.sync {}
        let queued = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(queued.compactMap { $0[OursPrivacyPersistence.localIdentityModeKey] as? Bool },
                       [false, false, false, false, true, true, true])
        XCTAssertEqual(queued.prefix(3).map { $0["distinct_id"] as? String },
                       original.map { $0["distinct_id"] as? String })

        _ = op.mobileSession?.background(at: MobileTimePoint(
            epochMs: start.epochMs + 20_000, monotonicMs: start.monotonicMs + 20_000))
        let restored = MobileSession(instanceName: op.name)
        let reopened = restored.foreground(
            automaticEnabled: true, visitorId: visitor, isManuallySetId: true,
            at: MobileTimePoint(epochMs: start.epochMs + 1_820_000, monotonicMs: start.monotonicMs + 1_820_000))
        let ended = try XCTUnwrap(reopened.first { $0.name == "$mobile_session_end" })
        XCTAssertEqual(ended.sid, sid)
        XCTAssertEqual(ended.isManuallySetId, true)
    }

    func testPendingCanonicalFactsKeepCapturedIdentityModeAfterFailedQueueWrite() async throws {
        let token = "pending-identity-\(UUID().uuidString)"
        defer {
            OursPrivacyPersistence.deleteUserDefaultsData(instanceName: token)
            UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)?
                .removeObject(forKey: "oursprivacy-\(token)-OPMobileSession")
        }
        let op = OursPrivacy(token: token, trackAutomaticEvents: true)
        op.mobileSession = MobileSession(instanceName: token)
        op.mobileRuntimeEnabled = true
        await op.initialize()
        let persist = op.oursprivacyPersistence.persistenceWrite
        op.oursprivacyPersistence.persistenceWrite = { _ in false }
        op.mobileForeground(at: MobileTimePoint.capture())
        op.trackingQueue.sync {}
        XCTAssertEqual(op.mobileSession?.pendingFacts.count, 3)

        op.setVisitorId(op.visitorId)
        op.oursprivacyPersistence.persistenceWrite = persist
        op.trackScreen("Schedule")
        op.trackingQueue.sync {}
        let queue = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        XCTAssertEqual(queue.filter { $0["event"] as? String == "$mobile_first_open" }.count, 1)
        let success = ingestResult(#"{"success":true,"visitor_id":"visitor"}"#)
        let request = ScriptedIngestRequest(responses: [success, success, success])
        op.flushInstance.flushRequest = request
        op.flushQueue(queue, type: .events)

        let envelopes = request.sentEnvelopes
        XCTAssertEqual(envelopes.compactMap { $0["is_manually_set_id"] as? Bool }, [false, true])
        let first = try XCTUnwrap(envelopes.first?["data"] as? Queue)
        XCTAssertTrue(first.contains { $0["event"] as? String == "$mobile_first_open" })
        let last = try XCTUnwrap(envelopes.last?["data"] as? Queue)
        XCTAssertEqual(last.last?["event"] as? String, "$mobile_screen_view")
        XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    func testOlderRowsUseCurrentIdentityModeAndStillSeparateVisitors() {
        for manual in [false, true] {
            let op = makeTask5Instance()
            if manual { op.setVisitorId("current-visitor") }
            for visitor in ["older-a", "older-b"] {
                XCTAssertTrue(op.oursprivacyPersistence.saveEntity([
                    "event": "older", "visitor_id": visitor, "distinct_id": UUID().uuidString,
                    "eventProperties": NSNull(), "userProperties": NSNull(), "defaultProperties": [:]
                ], type: .events))
            }
            let success = ingestResult(#"{"success":true,"visitor_id":"visitor"}"#)
            let request = ScriptedIngestRequest(responses: [success, success])
            op.flushInstance.flushRequest = request
            op.flushQueue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)

            XCTAssertEqual(request.sentEnvelopes.count, 2)
            XCTAssertEqual(request.sentEnvelopes.compactMap { $0["is_manually_set_id"] as? Bool }, [manual, manual])
            XCTAssertEqual(request.sentEnvelopes.compactMap { ($0["data"] as? Queue)?.first?["visitor_id"] as? String },
                           ["older-a", "older-b"])
            XCTAssertTrue(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        }
    }

    func testFlushSeparatesCapturedVisitorAndIdentityModeAcrossRestart() throws {
        let token = "visitor-batches-\(UUID().uuidString)"
        defer { OursPrivacyPersistence.deleteUserDefaultsData(instanceName: token) }
        let original = OursPrivacy(token: token, trackAutomaticEvents: false)
        let anonymousVisitor = original.visitorId
        original.track(event: "anonymous")
        original.trackingQueue.sync {}
        original.setVisitorId(anonymousVisitor)
        original.track(event: "explicit-same-visitor")
        original.trackingQueue.sync {}
        original.setVisitorId("linked-visitor")
        original.identify(OursPrivacyUserProperties(externalId: "profile-1"))
        original.track(event: "linked")
        original.trackingQueue.sync {}

        let restarted = OursPrivacy(token: token, trackAutomaticEvents: false)
        let success = ingestResult(#"{"success":true,"visitor_id":"visitor"}"#)
        let request = ScriptedIngestRequest(responses: [success, success, success])
        restarted.flushInstance.flushRequest = request
        restarted.flushQueue(restarted.oursprivacyPersistence.loadEntitiesInBatch(type: .events), type: .events)

        XCTAssertTrue(restarted.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        XCTAssertEqual(request.sentEnvelopes.count, 3)
        XCTAssertEqual(request.sentEnvelopes.compactMap { $0["is_manually_set_id"] as? Bool }, [false, true, true])
        let batches = request.sentEnvelopes.compactMap { $0["data"] as? Queue }
        XCTAssertEqual(batches.map { $0.compactMap { $0["event"] as? String } },
                       [["anonymous"], ["explicit-same-visitor"], ["$identify", "linked"]])
        XCTAssertEqual(batches.map { $0.compactMap { $0["visitor_id"] as? String } },
                       [[anonymousVisitor], [anonymousVisitor], ["linked-visitor", "linked-visitor"]])
        for item in batches.flatMap({ $0 }) {
            XCTAssertEqual(Set(item.keys), Set(["event", "visitor_id", "distinct_id",
                                                "eventProperties", "userProperties", "defaultProperties"]))
        }
    }

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
            #"{"success":true,"visitor_id":"visitor","accepted_count":1}"#,
            #"{"success":true,"visitor_id":""}"#,
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

    func testIndexedModePersistsAcrossRestartAndAcceptsLegacySuccess() {
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
        XCTAssertTrue(restarted.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        XCTAssertTrue(restarted.oursprivacyPersistence.hasIndexedIngestMode)
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
            XCTAssertTrue(restarted.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty, privacyAction)
            XCTAssertTrue(restarted.oursprivacyPersistence.hasIndexedIngestMode)
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
