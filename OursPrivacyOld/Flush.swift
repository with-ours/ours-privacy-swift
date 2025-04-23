//
//  Flush.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Yarden Eitan on 6/3/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//

import Foundation

protocol FlushDelegate: AnyObject {
    func flush(performFullFlush: Bool, completion: (() -> Void)?)
    func flushSuccess(type: FlushType, ids: [Int32])
    
    #if os(iOS)
    func updateNetworkActivityIndicator(_ on: Bool)
    #endif // os(iOS)
}

class Flush: AppLifecycle {
    var timer: Timer?
    weak var delegate: FlushDelegate?
    var useIPAddressForGeoLocation = true
    var flushRequest: FlushRequest
    var flushOnBackground = true
    var _flushInterval = 0.0
    var _flushBatchSize = APIConstants.maxBatchSize
    private var _serverURL =  BasePath.DefaultAPIEndpoint
    private let flushRequestReadWriteLock: DispatchQueue

    
    var serverURL: String {
        get {
            flushRequestReadWriteLock.sync {
                return _serverURL
            }
        }
        set {
            flushRequestReadWriteLock.sync(flags: .barrier, execute: {
                _serverURL = newValue
                self.flushRequest.serverURL = newValue
            })
        }
    }
    
    var flushInterval: Double {
        get {
            flushRequestReadWriteLock.sync {
                return _flushInterval
            }
        }
        set {
            flushRequestReadWriteLock.sync(flags: .barrier, execute: {
                _flushInterval = newValue
            })

            delegate?.flush(performFullFlush: false, completion: nil)
            startFlushTimer()
        }
    }
    
    var flushBatchSize: Int {
        get {
            return _flushBatchSize
        }
        set {
            _flushBatchSize = newValue
        }
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
            guard let self = self else {
                return
            }

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

    func flushQueueInBatches(_ queue: Queue, type: FlushType, headers: [String: String], queryItems: [URLQueryItem]) {
        var mutableQueue = queue
        while !mutableQueue.isEmpty {
            let batchSize = 1 //min(mutableQueue.count, flushBatchSize)
//            let range = 0..<1 //batchSize
            let batch = mutableQueue[0] // Array(mutableQueue[range])
//            let ids: [Int32] = batch.map { entity in
//                (entity["id"] as? Int32) ?? 0
//            }
            let id = batch["id"] as? Int32 ?? 0
            // Log data payload sent
//            OursPrivacyLogger.debug(message: "Sending batch of data")
//            OursPrivacyLogger.debug(message: batch as Any)
            let requestData = JSONHandler.encodeAPIData(batch)
            if let requestData = requestData {
                #if os(iOS)
                    if !OursPrivacyInstance.isiOSAppExtension() {
                        delegate?.updateNetworkActivityIndicator(true)
                    }
                #endif // os(iOS)
                let success = flushRequest.sendRequest(requestData,
                                                       type: type,
                                                       useIP: useIPAddressForGeoLocation,
                                                       headers: headers,
                                                       queryItems: queryItems)
                #if os(iOS)
                if !OursPrivacyInstance.isiOSAppExtension() {
                    delegate?.updateNetworkActivityIndicator(false)
                }
                #endif // os(iOS)
                if success {
                    // remove
                    delegate?.flushSuccess(type: type, ids: [id])
                    mutableQueue = self.removeProcessedBatch(batchSize: batchSize,
                                                                queue: mutableQueue,
                                                                type: type)
                } else {
                    break
                }
            }
        }
    }
    
    func removeProcessedBatch(batchSize: Int, queue: Queue, type: FlushType) -> Queue {
        var shadowQueue = queue
        let range = 0..<batchSize
        if let lastIndex = range.last, shadowQueue.count - 1 > lastIndex {
            shadowQueue.removeSubrange(range)
        } else {
            shadowQueue.removeAll()
        }
        return shadowQueue
    }

    // MARK: - Lifecycle
    func applicationDidBecomeActive() {
        startFlushTimer()
    }

    func applicationWillResignActive() {
        stopFlushTimer()
    }

}

