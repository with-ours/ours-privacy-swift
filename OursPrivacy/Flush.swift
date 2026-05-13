//
//  Flush.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//

import Foundation

protocol FlushDelegate: AnyObject {
    func flush(performFullFlush: Bool, completion: (() -> Void)?)
    func flushSuccess(type: FlushType, ids: [Int32])
    func flushEnvelopeContext() -> (token: String, isManuallySetId: Bool)
}

class Flush: AppLifecycle {
    var timer: Timer?
    weak var delegate: FlushDelegate?
    var flushRequest: FlushRequest
    var flushOnBackground = true
    var _flushInterval = 0.0
    var _flushBatchSize = APIConstants.maxBatchSize
    private var _serverURL = BasePath.DefaultAPIEndpoint
    private let flushRequestReadWriteLock: DispatchQueue

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
            delegate?.flush(performFullFlush: false, completion: nil)
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
        flushRequestReadWriteLock = DispatchQueue(label: "com.oursprivacy.flush_interval.lock", qos: .utility, attributes: .concurrent, autoreleaseFrequency: .workItem)
    }

    func flushQueue(_ queue: Queue, type: FlushType, headers: [String: String], queryItems: [URLQueryItem]) {
        if flushRequest.requestNotAllowed() {
            return
        }
        flushQueueInBatches(queue, type: type, headers: headers, queryItems: queryItems)
    }

    func startFlushTimer() {
        stopFlushTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.flushInterval > 0 {
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(timeInterval: self.flushInterval,
                                                  target: self,
                                                  selector: #selector(self.flushSelector),
                                                  userInfo: nil,
                                                  repeats: true)
            }
        }
    }

    @objc func flushSelector() {
        delegate?.flush(performFullFlush: false, completion: nil)
    }

    func stopFlushTimer() {
        if let timer = timer {
            DispatchQueue.main.async { [weak self, timer] in
                timer.invalidate()
                self?.timer = nil
            }
        }
    }

    /// Drains the queue in `flushBatchSize` chunks. Each chunk becomes one
    /// `/ingest` POST body of shape `{token, is_manually_set_id, data: [items]}`.
    /// On success we delete the chunk's SQLite row IDs and continue; on failure
    /// we stop so a retry can pick up where this attempt left off.
    func flushQueueInBatches(_ queue: Queue, type: FlushType, headers: [String: String], queryItems: [URLQueryItem]) {
        guard let context = delegate?.flushEnvelopeContext() else { return }

        var mutableQueue = queue
        while !mutableQueue.isEmpty {
            let batchSize = min(mutableQueue.count, flushBatchSize)
            let batch = Array(mutableQueue.prefix(batchSize))
            let ids: [Int32] = batch.compactMap { $0["id"] as? Int32 }

            // Strip the SQLite `id` column from each item — it's local state, not
            // part of the wire schema.
            let items = batch.map { row -> InternalProperties in
                var copy = row
                copy.removeValue(forKey: "id")
                return copy
            }

            let envelope: InternalProperties = [
                "token": context.token,
                "is_manually_set_id": context.isManuallySetId,
                "data": items,
            ]

            guard let requestData = JSONHandler.encodeAPIData(envelope) else {
                OursPrivacyLogger.warn(message: "flush dropped a batch: envelope failed to serialize")
                mutableQueue.removeFirst(batchSize)
                continue
            }

            let success = flushRequest.sendRequest(requestData,
                                                   type: type,
                                                   headers: headers,
                                                   queryItems: queryItems)
            if success {
                delegate?.flushSuccess(type: type, ids: ids)
                mutableQueue.removeFirst(batchSize)
            } else {
                break
            }
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
