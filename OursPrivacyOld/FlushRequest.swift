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
    case events = "/track"
    case identify = "/identify"
//    case people = "/identify/"
//    case groups = "/groups/"
}

class FlushRequest: Network {

    var networkRequestsAllowedAfterTime = 0.0
    var networkConsecutiveFailures = 0

    func sendRequest(_ requestData: String,
                     type: FlushType,
                     useIP: Bool,
                     headers: [String: String],
                     queryItems: [URLQueryItem] = []) -> Bool {
        
        OursPrivacyLogger.debug(message: "sendRequest: type \(type), data: \(requestData)")

//        let responseParser: (Data) -> Int? = { data in
//            let response = String(data: data, encoding: String.Encoding.utf8)
//            if let response = response {
//                return Int(response) ?? 0
//            }
//            return nil
//        }
        
        let responseParser: (Data) -> OursResponse = { data in
            var finalResponse = OursResponse(success: false)
            do {
                let responseJson = try JSONSerialization.jsonObject(with: data, options: [])
                if let dictionary = responseJson as? [String: Any] {
                    finalResponse = OursResponse(success: dictionary["success"] as? Bool ?? false)
                }
            }
            catch {
                // return default
            }
            return finalResponse
            
        }
        
        let resourceHeaders: [String: String] = ["Content-Type": "application/json"].merging(headers) {(_,new) in new }

        var resourceQueryItems: [URLQueryItem] = []
        resourceQueryItems.append(contentsOf: queryItems)
        let resource = Network.buildResource(path: type.rawValue,
                                             method: .post,
                                             requestBody: requestData.data(using: .utf8),
                                             queryItems: resourceQueryItems,
                                             headers: resourceHeaders,
                                             parse: responseParser)
        var result = false
        let semaphore = DispatchSemaphore(value: 0)
        flushRequestHandler(serverURL,
                            resource: resource,
                            completion: { success in
                                result = success
                                semaphore.signal()
        })
        _ = semaphore.wait(timeout: .now() + 120.0)
        return result
    }


    private func flushRequestHandler(_ base: String,
                                     resource: Resource<OursResponse>,
                                     completion: @escaping (Bool) -> Void) {

        Network.apiRequest(base: base, resource: resource,
            failure: { (reason, _, response) in
                self.networkConsecutiveFailures += 1
                self.updateRetryDelay(response)
                OursPrivacyLogger.warn(message: "API request to \(resource.path) has failed with reason \(reason)")
                completion(false)
            }, success: { (result, response) in
                self.networkConsecutiveFailures = 0
                self.updateRetryDelay(response)
                if result.success == false {
                    OursPrivacyLogger.info(message: "\(base) api request faield")
                }
                completion(true)
            })
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
        let time = pow(2.0, Double(failureCount) - 1) * 60 + Double(arc4random_uniform(30))
        return min(max(APIConstants.minRetryBackoff, time),
                   APIConstants.maxRetryBackoff)
    }

    func requestNotAllowed() -> Bool {
        return Date().timeIntervalSince1970 < networkRequestsAllowedAfterTime
    }

}

