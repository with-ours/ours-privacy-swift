//
//  FlushRequest.swift
//  Ours Privacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Yarden Eitan on 7/8/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//

import Foundation

enum FlushType: String {
    // Everything flushes through `/ingest`. The wire-shape `event` name
    // (e.g. `$identify`) tells the server how to route the payload.
    case events = "/ingest"
}

struct IngestRejection: Decodable, Sendable {
    let index: Int
    let code: String
}

struct IngestBatchResult: Decodable, Sendable {
    let success: Bool
    let visitorId: String
    let accepted: Int?
    let rejected: [IngestRejection]?

    enum CodingKeys: String, CodingKey {
        case success
        case visitorId = "visitor_id"
        case accepted
        case rejected
    }

    var isIndexed: Bool { accepted != nil && rejected != nil }

    static func parse(_ data: Data) -> IngestBatchResult? {
        guard let result = try? JSONDecoder().decode(Self.self, from: data),
              result.success, !result.visitorId.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let hasAccepted = object.keys.contains("accepted")
        let hasRejected = object.keys.contains("rejected")
        guard hasAccepted == hasRejected else { return nil }
        if hasAccepted && !result.isIndexed { return nil }
        return result
    }
}

private final class RequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: IngestBatchResult?

    func finish(_ result: IngestBatchResult?) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> IngestBatchResult? {
        _ = semaphore.wait(timeout: .now() + 120)
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

// The network queue waits for each URLSession callback before issuing another request.
class FlushRequest: Network, @unchecked Sendable {

    var networkRequestsAllowedAfterTime = 0.0
    var networkConsecutiveFailures = 0
    private let activeRequestLock = NSLock()
    private var activeTask: URLSessionDataTask?
    private var privacyGeneration: UInt64 = 0

    var requestGeneration: UInt64 {
        activeRequestLock.lock()
        defer { activeRequestLock.unlock() }
        return privacyGeneration
    }

    func cancelActiveRequest() {
        activeRequestLock.lock()
        privacyGeneration &+= 1
        let task = activeTask
        activeTask = nil
        activeRequestLock.unlock()
        task?.cancel()
    }

    private func isCurrentRequest(_ generation: UInt64) -> Bool {
        activeRequestLock.lock()
        defer { activeRequestLock.unlock() }
        return generation == privacyGeneration
    }

    func sendRequest(_ requestData: String,
                     type: FlushType,
                     headers: [String: String],
                     queryItems: [URLQueryItem] = [],
                     generation: UInt64) -> IngestBatchResult? {

        let resourceHeaders: [String: String] = ["Content-Type": "application/json"].merging(headers) {(_, new) in new }

        var resourceQueryItems: [URLQueryItem] = []
        resourceQueryItems.append(contentsOf: queryItems)
        let resource = Network.buildResource(path: type.rawValue,
                                             method: .post,
                                             requestBody: requestData.data(using: .utf8),
                                             queryItems: resourceQueryItems,
                                             headers: resourceHeaders,
                                             parse: { data in IngestBatchResult.parse(data) })
        let completion = RequestCompletion()
        let task = flushRequestHandler(serverURL, resource: resource, generation: generation) {
            completion.finish($0)
        }
        activeRequestLock.lock()
        guard generation == privacyGeneration else {
            activeRequestLock.unlock()
            task?.cancel()
            return nil
        }
        activeTask = task
        activeRequestLock.unlock()
        OursPrivacyLogger.debug(message: "sendRequest: type \(type), data: \(requestData)")
        task?.resume()
        let result = completion.wait()
        activeRequestLock.lock()
        if activeTask === task { activeTask = nil }
        let isCurrent = generation == privacyGeneration
        activeRequestLock.unlock()
        return isCurrent ? result : nil
    }

    private func flushRequestHandler(_ base: String,
                                     resource: Resource<IngestBatchResult>,
                                     generation: UInt64,
                                     completion: @escaping @Sendable (IngestBatchResult?) -> Void) -> URLSessionDataTask? {
        let task = Network.makeRequestTask(base: base, resource: resource,
            failure: { (reason, _, response) in
                guard self.isCurrentRequest(generation) else { completion(nil); return }
                self.networkConsecutiveFailures += 1
                self.updateRetryDelay(response)
                OursPrivacyLogger.warn(message: "API request to \(resource.path) has failed with reason \(reason)")
                completion(nil)
            }, success: { (result, response) in
                guard self.isCurrentRequest(generation) else { completion(nil); return }
                self.networkConsecutiveFailures = 0
                self.updateRetryDelay(response)
                completion(result)
            })
        if task == nil { completion(nil) }
        return task
    }

    private func updateRetryDelay(_ response: URLResponse?) {
        var retryTime = 0.0
        let retryHeader = (response as? HTTPURLResponse)?.allHeaderFields["Retry-After"] as? String
        if let retryHeader = retryHeader, let retryHeaderParsed = (Double(retryHeader)) {
            retryTime = retryHeaderParsed
        }

        if networkConsecutiveFailures >= APIConstants.failuresTillBackoff {
            retryTime = max(retryTime,
                            retryBackOffTimeWithConsecutiveFailures(networkConsecutiveFailures))
        }
        let retryDate = Date(timeIntervalSinceNow: retryTime)
        networkRequestsAllowedAfterTime = retryDate.timeIntervalSince1970
    }

    private func retryBackOffTimeWithConsecutiveFailures(_ failureCount: Int) -> TimeInterval {
        let time = pow(2.0, Double(failureCount) - 1) * 60 + Double(Int.random(in: 0 ..< 30))
        return min(max(APIConstants.minRetryBackoff, time),
                   APIConstants.maxRetryBackoff)
    }

    func requestNotAllowed() -> Bool {
        return Date().timeIntervalSince1970 < networkRequestsAllowedAfterTime
    }

}
