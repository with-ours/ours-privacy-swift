//
//  Flush.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//

import Foundation

protocol FlushDelegate: AnyObject {
    func flushAutomatically(performFullFlush: Bool, completion: (@Sendable () -> Void)?)
    func canFlushBatch(type: FlushType, rows: Queue) -> Bool
    func acknowledgeFlush(type: FlushType, rowIDs: [String]) -> Bool
    func hasIndexedIngestMode() -> Bool
    func persistIndexedIngestMode() -> Bool
    func reportIngestRejection(distinctId: String, code: String)
    func flushEnvelopeContext() -> (token: String, isManuallySetId: Bool)
}

// The timer stays on the main queue; URL and interval changes use flushRequestReadWriteLock.
class Flush: AppLifecycle, @unchecked Sendable {
    var timer: Timer?
    weak var delegate: FlushDelegate?
    var flushRequest: FlushRequest
    var flushOnBackground = true
    var _flushInterval = 0.0
    var _flushBatchSize = APIConstants.maxBatchSize
    private var _serverURL = BasePath.DefaultAPIEndpoint
    private let flushRequestReadWriteLock: DispatchQueue
    private var invalidAcknowledgmentHead: String?
    private var invalidAcknowledgmentGeneration: UInt64?
    private var invalidAcknowledgmentCount = 0

    var serverURL: String {
        get {
            flushRequestReadWriteLock.sync { _serverURL }
        }
        set {
            flushRequestReadWriteLock.sync(flags: .barrier) {
                _serverURL = newValue
                self.flushRequest.serverURL = newValue
            }
        }
    }

    var flushInterval: Double {
        get {
            flushRequestReadWriteLock.sync { _flushInterval }
        }
        set {
            flushRequestReadWriteLock.sync(flags: .barrier) {
                _flushInterval = newValue
            }
            delegate?.flushAutomatically(performFullFlush: false, completion: nil)
            startFlushTimer()
        }
    }

    var flushBatchSize: Int {
        get { _flushBatchSize }
        set { _flushBatchSize = newValue }
    }

    required init(serverURL: String) {
        self.flushRequest = FlushRequest(serverURL: serverURL)
        _serverURL = serverURL
        flushRequestReadWriteLock = DispatchQueue(label: "com.oursprivacy.flush_interval.lock",
                                                   qos: .utility,
                                                   attributes: .concurrent,
                                                   autoreleaseFrequency: .workItem)
    }

    func flushQueue(_ queue: Queue, type: FlushType, headers: [String: String], queryItems: [URLQueryItem]) {
        if flushRequest.requestNotAllowed() {
            return
        }
        flushQueueInBatches(queue, type: type, headers: headers, queryItems: queryItems)
    }

    func startFlushTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timer?.invalidate()
            self.timer = nil
            if self.flushInterval > 0 {
                self.timer = Timer.scheduledTimer(timeInterval: self.flushInterval,
                                                  target: self,
                                                  selector: #selector(self.flushSelector),
                                                  userInfo: nil,
                                                  repeats: true)
            }
        }
    }

    @objc func flushSelector() {
        delegate?.flushAutomatically(performFullFlush: false, completion: nil)
    }

    func stopFlushTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    /// Drains the queue in `flushBatchSize` chunks. Each chunk becomes one
    /// `/ingest` POST body of shape `{token, is_manually_set_id, data: [items]}`.
    /// On success we delete the chunk's local rows and continue; on failure
    /// we stop so a retry can pick up where this attempt left off.
    func flushQueueInBatches(_ queue: Queue, type: FlushType, headers: [String: String], queryItems: [URLQueryItem]) {
        guard let context = delegate?.flushEnvelopeContext() else { return }
        let generation = flushRequest.requestGeneration

        var mutableQueue = queue
        while !mutableQueue.isEmpty {
            guard flushRequest.requestGeneration == generation else { break }
            let head = mutableQueue[0]
            guard let visitorId = head["visitor_id"] as? String, !visitorId.isEmpty else {
                guard let rowID = head[OursPrivacyPersistence.localRowIDKey] as? String,
                      delegate?.canFlushBatch(type: type, rows: [head]) == true,
                      flushRequest.requestGeneration == generation,
                      delegate?.acknowledgeFlush(type: type, rowIDs: [rowID]) == true,
                      flushRequest.requestGeneration == generation else { break }
                if let distinctId = head["distinct_id"] as? String {
                    delegate?.reportIngestRejection(distinctId: distinctId, code: "invalid_visitor_id")
                }
                mutableQueue.removeFirst()
                continue
            }
            let manualId = mutableQueue[0][OursPrivacyPersistence.localIdentityModeKey] as? Bool ?? context.isManuallySetId
            let batch = Array(mutableQueue.prefix(max(1, flushBatchSize)).prefix { row in
                row["visitor_id"] as? String == visitorId &&
                    (row[OursPrivacyPersistence.localIdentityModeKey] as? Bool ?? context.isManuallySetId) == manualId
            })
            let batchSize = batch.count
            let rowIDs = batch.compactMap { $0[OursPrivacyPersistence.localRowIDKey] as? String }

            let items = batch.map { row -> InternalProperties in
                var copy = row
                copy.removeValue(forKey: "id")
                copy.removeValue(forKey: OursPrivacyPersistence.localRowIDKey)
                copy.removeValue(forKey: OursPrivacyPersistence.localIdentityModeKey)
                return copy
            }

            let envelope: InternalProperties = [
                "token": context.token,
                "is_manually_set_id": manualId,
                "data": items
            ]

            guard let requestData = JSONHandler.encodeAPIData(envelope) else {
                OursPrivacyLogger.warn(message: "flush dropped a batch: envelope failed to serialize")
                mutableQueue.removeFirst(batchSize)
                continue
            }

            guard rowIDs.count == batch.count, delegate?.canFlushBatch(type: type, rows: batch) == true else {
                break
            }
            guard let result = flushRequest.sendRequest(requestData,
                                                        type: type,
                                                        headers: headers,
                                                        queryItems: queryItems,
                                                        generation: generation),
                  flushRequest.requestGeneration == generation,
                  delegate?.canFlushBatch(type: type, rows: batch) == true else { break }
            var malformed = result.invalidAcknowledgment
            var callbacks: [(String, String)] = []
            if let code = result.rejectionCode {
                callbacks = batch.compactMap { row in
                    guard let distinctId = row["distinct_id"] as? String else { return nil }
                    return (distinctId, code)
                }
            } else if result.isIndexed, let accepted = result.accepted, let rejected = result.rejected {
                malformed = accepted < 0 || accepted > batch.count || rejected.count != batch.count - accepted
                var indexes = Set<Int>()
                for rejection in rejected {
                    guard rejection.index >= 0, rejection.index < batch.count,
                          indexes.insert(rejection.index).inserted,
                          !rejection.code.isEmpty,
                          let distinctId = batch[rejection.index]["distinct_id"] as? String,
                          !distinctId.isEmpty else {
                        malformed = true
                        break
                    }
                    callbacks.append((distinctId, rejection.code))
                }
            } else if !result.success {
                break
            }
            if malformed {
                if invalidAcknowledgmentHead != rowIDs.first || invalidAcknowledgmentGeneration != generation {
                    invalidAcknowledgmentHead = rowIDs.first
                    invalidAcknowledgmentGeneration = generation
                    invalidAcknowledgmentCount = 0
                }
                invalidAcknowledgmentCount += 1
                guard invalidAcknowledgmentCount >= 5 else { break }
                callbacks = batch.compactMap { row in
                    guard let distinctId = row["distinct_id"] as? String else { return nil }
                    return (distinctId, "invalid_acknowledgment")
                }
            } else if result.isIndexed {
                guard delegate?.persistIndexedIngestMode() == true else { break }
            }
            guard delegate?.acknowledgeFlush(type: type, rowIDs: rowIDs) == true else { break }
            invalidAcknowledgmentHead = nil
            invalidAcknowledgmentGeneration = nil
            invalidAcknowledgmentCount = 0
            for (distinctId, code) in callbacks {
                guard flushRequest.requestGeneration == generation else { break }
                delegate?.reportIngestRejection(distinctId: distinctId, code: code)
            }
            mutableQueue.removeFirst(batchSize)
        }
    }

    // MARK: - Lifecycle
    func applicationDidBecomeActive() {
        startFlushTimer()
    }

    func applicationWillResignActive() {
        stopFlushTimer()
    }
}
