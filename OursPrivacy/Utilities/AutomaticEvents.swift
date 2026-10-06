//
//  AutomaticEvents.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Yarden Eitan on 3/8/17.
//  Copyright © 2017 OursPrivacy. All rights reserved.
//

protocol AEDelegate: AnyObject {
    func track(event: String?, properties: Properties?, userProperties: Properties?)
    func setOnce(properties: Properties)
    func increment(property: String, by: Double)
    func mobileForeground(at point: MobileTimePoint)
    func mobileBackground(at point: MobileTimePoint)
}

#if os(iOS) || os(tvOS) || os(visionOS)
import Foundation
import UIKit
import StoreKit

// StoreKit purchase state uses awaitingTransactionsWriteLock; lifecycle callbacks update session state on the main queue.
class AutomaticEvents: NSObject, SKPaymentTransactionObserver, SKProductsRequestDelegate, @unchecked Sendable {

    var _minimumSessionDuration: UInt64 = 10000
    var minimumSessionDuration: UInt64 {
        get {
            return _minimumSessionDuration
        }
        set {
            _minimumSessionDuration = newValue
        }
    }
    var _maximumSessionDuration: UInt64 = UINT64_MAX
    var maximumSessionDuration: UInt64 {
        get {
            return _maximumSessionDuration
        }
        set {
            _maximumSessionDuration = newValue
        }
    }

    var awaitingTransactions = [String: Int]()
    var productsRequests: [ObjectIdentifier: SKProductsRequest] = [:]
    let defaults = UserDefaults(suiteName: "OursPrivacy")
    weak var delegate: AEDelegate?
    var sessionLength: TimeInterval = 0
    var sessionStartTime: TimeInterval = Date().timeIntervalSince1970
    var hasAddedObserver = false

    let awaitingTransactionsWriteLock = DispatchQueue(label: "com.oursprivacy.awaiting_transactions_writeLock",
                                                       qos: .userInitiated,
                                                       autoreleaseFrequency: .workItem)

    func registerLifecycleListeners() {
        guard !hasAddedObserver else { return }
        hasAddedObserver = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appWillResignActive(_:)),
                                               name: UIApplication.willResignActiveNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidBecomeActive(_:)),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
    }

    func initializeEvents(instanceName: String) {
        let legacyFirstOpenKey = "OPFirstOpen"
        let firstOpenKey = "OPFirstOpen-\(instanceName)"
        // do not track `$ae_first_open` again if the legacy key exist,
        // but we will start using the key with the ours token in favour of multiple instances support
        if let defaults = defaults, !defaults.bool(forKey: legacyFirstOpenKey) {
            if !defaults.bool(forKey: firstOpenKey) {
                defaults.set(true, forKey: firstOpenKey)
                defaults.synchronize()
                delegate?.track(event: "$ae_first_open", properties: ["$ae_first_app_open_date": Date()], userProperties: nil)
                delegate?.setOnce(properties: ["$ae_first_app_open_date": Date()])
            }
        }
        if let defaults = defaults, let infoDict = Bundle.main.infoDictionary {
            let appVersionKey = "OPAppVersion"
            let appVersionValue = infoDict["CFBundleShortVersionString"]
            let savedVersionValue = defaults.string(forKey: appVersionKey)
            if let appVersionValue = appVersionValue as? String,
               let savedVersionValue = savedVersionValue,
               appVersionValue.compare(savedVersionValue, options: .numeric, range: nil, locale: nil) == .orderedDescending {
                delegate?.track(event: "$ae_updated", properties: ["$ae_updated_version": appVersionValue], userProperties: nil)
                defaults.set(appVersionValue, forKey: appVersionKey)
                defaults.synchronize()
            } else if savedVersionValue == nil {
                defaults.set(appVersionValue, forKey: appVersionKey)
                defaults.synchronize()
            }
        }

        registerLifecycleListeners()
        SKPaymentQueue.default().add(self)
    }

    @objc func appWillResignActive(_ notification: Notification) {
        let point = MobileTimePoint.capture()
        delegate?.mobileBackground(at: point)
        sessionLength = roundOneDigit(num: Date().timeIntervalSince1970 - sessionStartTime)
        if sessionLength >= Double(minimumSessionDuration / 1000) &&
            sessionLength <= Double(maximumSessionDuration / 1000) {
            delegate?.track(event: "$ae_session", properties: ["$ae_session_length": sessionLength], userProperties: nil)
            delegate?.increment(property: "$ae_total_app_sessions", by: 1)
            delegate?.increment(property: "$ae_total_app_session_length", by: sessionLength)
        }
    }

    @objc func appDidBecomeActive(_ notification: Notification) {
        let point = MobileTimePoint.capture()
        delegate?.mobileForeground(at: point)
        sessionStartTime = Date().timeIntervalSince1970
    }

    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        let purchased = transactions.compactMap { transaction -> (String, Int)? in
            guard transaction.transactionState == .purchased else { return nil }
            return (transaction.payment.productIdentifier, transaction.payment.quantity)
        }
        awaitingTransactionsWriteLock.async { [self] in
            for (identifier, quantity) in purchased {
                awaitingTransactions[identifier] = quantity
            }
            let productIdentifiers = Set(purchased.map(\.0))
            if !productIdentifiers.isEmpty {
                let request = SKProductsRequest(productIdentifiers: productIdentifiers)
                productsRequests[ObjectIdentifier(request)] = request
                request.delegate = self
                request.start()
            }
        }
    }

    func roundOneDigit(num: TimeInterval) -> TimeInterval {
        return round(num * 10.0) / 10.0
    }

    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        let requestID = ObjectIdentifier(request)
        let products = response.products.map { ($0.productIdentifier, "\($0.price)") }
        awaitingTransactionsWriteLock.async { [self] in
            for (identifier, price) in products {
                if let quantity = awaitingTransactions[identifier] {
                    delegate?.track(event: "$ae_iap", properties: ["$ae_iap_price": price,
                                                                   "$ae_iap_quantity": quantity,
                                                                   "$ae_iap_name": identifier], userProperties: nil)
                    awaitingTransactions.removeValue(forKey: identifier)
                }
            }
            productsRequests.removeValue(forKey: requestID)
        }
    }

    func request(_ request: SKRequest, didFailWithError error: Error) {
        let requestID = ObjectIdentifier(request)
        awaitingTransactionsWriteLock.async { [self] in
            productsRequests.removeValue(forKey: requestID)
        }
        OursPrivacyLogger.warn(message: "Product request failed: \(error)")
    }
}
#endif
