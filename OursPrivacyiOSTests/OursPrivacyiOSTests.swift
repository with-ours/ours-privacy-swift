//
//  OursPrivacyiOSTests.swift
//  OursPrivacyiOSTests
//
//  Created by Zeytech on 4/11/25.
//  Copyright © 2025 Ours Wellness Inc. All rights reserved.
//

import Foundation
import StoreKit
import Testing
import UIKit
@testable import OursPrivacyKit

private final class LockedTestMobileTime: @unchecked Sendable {
    private let lock = NSLock()
    private var point: MobileTimePoint

    init(_ point: MobileTimePoint) {
        self.point = point
    }

    func capture() -> MobileTimePoint {
        lock.lock()
        defer { lock.unlock() }
        return point
    }

    func advance(by milliseconds: Int64) {
        lock.lock()
        point = MobileTimePoint(epochMs: point.epochMs + milliseconds,
                                monotonicMs: point.monotonicMs + milliseconds)
        lock.unlock()
    }
}

struct OursPrivacyiOSTests {
    @Test @MainActor func legacyIdentityUpgradeIsRecognizedBeforeCleanup() async throws {
        let token = "ios-upgrade-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(token)-"
        let legacyKey = "\(prefix)\(OursPrivacyUserDefaultsKeys.legacyDistinctID)"
        defaults?.set("existing-install", forKey: legacyKey)
        let op = OursPrivacy(token: token, trackAutomaticEvents: true)
        op.flushInstance.delegate = nil
        op.flushInstance._flushInterval = 0
        defer {
            op.optOutTracking()
            op.trackingQueue.sync {}
            OursPrivacyPersistence.deleteUserDefaultsData(instanceName: token)
            defaults?.removeObject(forKey: legacyKey)
            defaults?.removeObject(forKey: "\(prefix)OPMobileSession")
            defaults?.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.legacyCleanupDone)")
        }

        #expect(defaults?.object(forKey: legacyKey) == nil)
        #expect(op.mobileSession?.hasAcceptedFirstOpen == true)
        await op.initialize()
        op.mobileForeground(at: MobileTimePoint.capture())
        op.trackingQueue.sync {}

        let names = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .compactMap { $0["event"] as? String }
        #expect(names.contains("$mobile_app_open"))
        #expect(names.contains("$mobile_session_start"))
        #expect(!names.contains("$mobile_first_open"))
    }

    @Test @MainActor func callerBagNearSerializedSizeLimitOmitsMetadata() async throws {
        let op = OursPrivacy(token: "ios-size-\(UUID().uuidString)", trackAutomaticEvents: false)
        op.flushInstance.delegate = nil
        op.flushInstance._flushInterval = 0
        defer {
            op.optOutTracking()
            op.trackingQueue.sync {}
            OursPrivacyPersistence.deleteUserDefaultsData(instanceName: op.name)
        }
        await op.initialize()
        let ordinary = ["field": String(repeating: "a", count: 1_048_563)]
        op.track(event: "large-booking", properties: ordinary.mapValues { $0 as OursPrivacyType })
        op.track(event: "following-booking")
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        #expect(items.count == 2)
        let properties = try #require(items.first?["eventProperties"] as? InternalProperties)
        let preserved = properties as NSDictionary == ordinary as NSDictionary
        #expect(preserved)
        #expect(try #require(JSONHandler.encodeAPIData(properties)).utf16.count == 1_048_575)
        #expect((items.first?["defaultProperties"] as? InternalProperties)?["sid"] is String)
        #expect((items.last?["eventProperties"] as? InternalProperties)?["mobile_contract_version"] as? Int == 1)
    }

    @Test @MainActor func sameVisitorModeChangePreservesSessionAndSplitsEngagement() async throws {
        let op = OursPrivacy(token: "ios-mode-\(UUID().uuidString)", trackAutomaticEvents: true)
        op.flushInstance.delegate = nil
        op.flushInstance._flushInterval = 0
        let clock = LockedTestMobileTime(MobileTimePoint.capture())
        op.captureMobileTime = { clock.capture() }
        op.mobileQueueNowMs = { clock.capture().epochMs }
        op.mobileCheckpointIntervalMs = 60_000
        defer {
            op.optOutTracking()
            op.trackingQueue.sync {}
        }
        await op.initialize()
        op.mobileForeground(at: clock.capture())
        op.trackingQueue.sync {}
        let visitor = try #require(op.getVisitorId())
        let initial = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let sid = try #require((initial.first?["defaultProperties"] as? InternalProperties)?["sid"] as? String)
        clock.advance(by: 5_000)

        op.setVisitorId(visitor)
        op.trackingQueue.sync {}
        clock.advance(by: 5_000)
        _ = op.mobileSession?.checkpoint(at: clock.capture())
        op.track(event: "after-mode-change")
        op.trackingQueue.sync {}
        clock.advance(by: 10_000)
        _ = op.mobileSession?.checkpoint(at: clock.capture())
        op.track(event: "later")
        op.trackingQueue.sync {}

        let queued = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let engagement = queued.filter { $0["event"] as? String == "$mobile_session_engagement" }
        #expect(engagement.compactMap { ($0["eventProperties"] as? InternalProperties)?["engagement_duration_ms"] as? Int64 }
                == [5_000, 5_000, 10_000])
        #expect(engagement.compactMap { $0[OursPrivacyPersistence.localIdentityModeKey] as? Bool } == [false, true, true])
        #expect(queued.allSatisfy { ($0["defaultProperties"] as? InternalProperties)?["sid"] as? String == sid })
        #expect(queued.last?[OursPrivacyPersistence.localIdentityModeKey] as? Bool == true)
    }

    @Test @MainActor func fullCallerBagOmitsMetadataWhileIdentifyAndFollowingEventKeepIt() async throws {
        let op = OursPrivacy(token: "ios-capacity-\(UUID().uuidString)", trackAutomaticEvents: false)
        op.flushInstance.delegate = nil
        op.flushInstance._flushInterval = 0
        await op.initialize()
        let ordinary = Dictionary(uniqueKeysWithValues: (0 ..< 200).map { ("field_\($0)", "value_\($0)") })

        op.track(event: "large-booking", properties: ordinary.mapValues { $0 as OursPrivacyType })
        op.identify(OursPrivacyUserProperties(externalId: "profile"))
        op.track(event: "following-booking")
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        #expect(items.count == 3)
        let first = try #require(items.first)
        #expect(first["eventProperties"] as? NSDictionary == ordinary as NSDictionary)
        #expect((first["defaultProperties"] as? InternalProperties)?["os_name"] as? String == "iOS")
        #expect((first["defaultProperties"] as? InternalProperties)?["sid"] is String)
        for item in items.dropFirst() {
            #expect((item["eventProperties"] as? InternalProperties)?["mobile_contract_version"] as? Int == 1)
        }
    }

    @Test func maxBatchSizeIsClampedAt50() async throws {
        #expect(APIConstants.maxBatchSize == 50)
    }

    @Test func optedOutByDefaultBlocksTrackingOnFreshInstance() async throws {
        let op = OursPrivacy(token: "ios-test-\(UUID().uuidString)", trackAutomaticEvents: false)
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        #expect(op.hasOptedOutTracking() == true)

        op.track(event: "should-be-dropped")
        op.trackingQueue.sync {}
        #expect(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    @Test @MainActor func defaultPropertiesDoNotWaitOnMainFromTrackingQueue() {
        AutomaticProperties.primeUIPropertiesIfOnMain()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            #expect(AutomaticProperties.defaultProperties["screen_width"] != nil)
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + .seconds(1)) == .success)
    }

    @Test @MainActor func primingOnMainReleasesBackgroundPreparedQueue() {
        let queue = DispatchQueue(label: "ios-mobile-preparation-\(UUID().uuidString)")
        let prepared = DispatchSemaphore(value: 0)
        let processed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            AutomaticProperties.prepareUIProperties(beforeProcessing: queue)
            prepared.signal()
        }
        #expect(prepared.wait(timeout: .now() + .seconds(2)) == .success)
        AutomaticProperties.primeUIPropertiesIfOnMain()
        queue.async { processed.signal() }
        #expect(processed.wait(timeout: .now() + .seconds(1)) == .success)
    }

    @Test @MainActor func iosRuntimeQueuesCanonicalOpenWithStitchedBooking() async {
        let op = OursPrivacy(token: "ios-mobile-\(UUID().uuidString)", trackAutomaticEvents: true)
        #expect(op.mobileRuntimeEnabled)
        await op.initialize(options: OursPrivacyInitOptions(
            initialURL: "https://example.test/?ours_visitor_id=linked-ios&utm_source=campaign",
            defaultEventProperties: ["caller_field": "private"]))
        op.mobileForeground(at: MobileTimePoint.capture())
        op.track(event: "appointment_booked")
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let mobile = items.filter { ($0["event"] as? String)?.hasPrefix("$mobile_") == true }
        #expect(mobile.filter { $0["event"] as? String == "$mobile_first_open" }.count == 1)
        #expect(mobile.filter { $0["event"] as? String == "$mobile_app_open" }.count == 1)
        let booked = items.first { $0["event"] as? String == "appointment_booked" }
        let openDefaults = mobile.first?["defaultProperties"] as? [String: Any]
        let bookedDefaults = booked?["defaultProperties"] as? [String: Any]
        #expect(openDefaults?["sid"] as? String == bookedDefaults?["sid"] as? String)
        #expect(mobile.allSatisfy { $0["visitor_id"] as? String == "linked-ios" })
        #expect(booked?["visitor_id"] as? String == "linked-ios")
        #expect(openDefaults?["mobile_platform"] == nil)
        #expect((mobile.first?["eventProperties"] as? [String: Any])?["mobile_contract_version"] as? Int == 1)
        #expect((openDefaults?["sid"] as? String)?.range(of: "^[0-9]{13}$", options: .regularExpression) != nil)
        #expect(openDefaults?["os_name"] as? String == "iOS")
        #expect(openDefaults?["utm_source"] == nil)
        #expect((mobile.first?["eventProperties"] as? [String: Any])?["caller_field"] == nil)
        #expect(bookedDefaults?["utm_source"] as? String == "campaign")
        #expect((booked?["eventProperties"] as? [String: Any])?["caller_field"] as? String == "private")
    }

    @Test @MainActor func iosRuntimeTracksExplicitScreenWithAutomaticLifecycleOff() async {
        let op = OursPrivacy(token: "ios-screen-\(UUID().uuidString)", trackAutomaticEvents: false)
        #expect(op.mobileRuntimeEnabled)
        await op.initialize()
        op.trackScreen("Schedule")
        op.trackScreen("Schedule")
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        #expect(items.map { $0["event"] as? String } == ["$mobile_screen_view"])
        #expect((items[0]["eventProperties"] as? [String: Any])?["screen_name"] as? String == "Schedule")
        #expect((items[0]["eventProperties"] as? [String: Any])?["mobile_contract_version"] as? Int == 1)
        #expect((items[0]["defaultProperties"] as? [String: Any])?["sid"] is String)

        op.optOutTracking()
        op.trackingQueue.sync {}
        op.trackScreen("Booking")
        op.trackingQueue.sync {}
        #expect(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    @Test @MainActor func inactiveOnlyResumePausesEngagementWithoutAnotherOpen() async {
        let op = OursPrivacy(token: "ios-inactive-\(UUID().uuidString)", trackAutomaticEvents: true)
        let clock = LockedTestMobileTime(MobileTimePoint.capture())
        op.captureMobileTime = { clock.capture() }
        op.mobileQueueNowMs = { clock.capture().epochMs }
        await op.initialize()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}
        let first = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let sid = (first.first?["defaultProperties"] as? [String: Any])?["sid"] as? String

        clock.advance(by: 9_000)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        op.trackingQueue.sync {}
        clock.advance(by: 60_000)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}
        clock.advance(by: 1_000)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let durations = items.filter { $0["event"] as? String == "$mobile_session_engagement" }
            .compactMap { ($0["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int64 }
        #expect(durations == [9_000, 1_000])
        #expect(items.filter { $0["event"] as? String == "$mobile_app_open" }.count == 1)
        #expect(items.filter { $0["event"] as? String == "$mobile_session_start" }.count == 1)
        #expect(items.allSatisfy {
            ($0["defaultProperties"] as? [String: Any])?["sid"] as? String == sid
        })
    }

    @Test @MainActor func realBackgroundThenActiveRecordsOneWarmOpen() async {
        let op = OursPrivacy(token: "ios-background-\(UUID().uuidString)", trackAutomaticEvents: true)
        let clock = LockedTestMobileTime(MobileTimePoint.capture())
        op.captureMobileTime = { clock.capture() }
        op.mobileQueueNowMs = { clock.capture().epochMs }
        await op.initialize()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}
        let first = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let sid = (first.first?["defaultProperties"] as? [String: Any])?["sid"] as? String

        clock.advance(by: 9_000)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        clock.advance(by: 60_000)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        clock.advance(by: 1_000)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        #expect(items.filter { $0["event"] as? String == "$mobile_app_open" }.count == 2)
        #expect(items.filter { $0["event"] as? String == "$mobile_session_start" }.count == 1)
        let opens = items.filter { $0["event"] as? String == "$mobile_app_open" }
        #expect(opens.allSatisfy {
            ($0["defaultProperties"] as? [String: Any])?["sid"] as? String == sid
        })
        let durations = items.filter { $0["event"] as? String == "$mobile_session_engagement" }
            .compactMap { ($0["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int64 }
        #expect(durations == [9_000])
    }

    @Test @MainActor func activeOptInQueuesCanonicalOpenBeforeOptInOnce() async {
        let op = OursPrivacy(token: "ios-opt-in-active-\(UUID().uuidString)", trackAutomaticEvents: true)
        let clock = LockedTestMobileTime(MobileTimePoint.capture())
        op.captureMobileTime = { clock.capture() }
        op.mobileQueueNowMs = { clock.capture().epochMs }
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}
        #expect(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)

        op.optInTracking()
        op.trackingQueue.sync {}
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let names = items.compactMap { $0["event"] as? String }
        #expect(names == ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start", "$opt_in"])
        #expect(op.mobileSession?.hasAcceptedFirstOpen == true)
        let sid = (items.first?["defaultProperties"] as? [String: Any])?["sid"] as? String
        #expect(!((sid ?? "").isEmpty))
        #expect(items.allSatisfy {
            ($0["defaultProperties"] as? [String: Any])?["sid"] as? String == sid
        })
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}
        #expect(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count == items.count)
    }

    @Test @MainActor func activeOptInWithAutomaticOffQueuesOnlyManualOptIn() async {
        let op = OursPrivacy(token: "ios-opt-in-manual-\(UUID().uuidString)", trackAutomaticEvents: false)
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}
        op.optInTracking()
        op.trackingQueue.sync {}
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        #expect(items.compactMap { $0["event"] as? String } == ["$opt_in"])
        #expect((items.first?["defaultProperties"] as? [String: Any])?["sid"] is String)
    }

    @Test @MainActor func activeOptInAfterTrackedOpenRotatesSessionWithoutRepeatingFirstOpen() async {
        let op = OursPrivacy(token: "ios-opt-in-again-\(UUID().uuidString)", trackAutomaticEvents: true)
        await op.initialize()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}
        let initial = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let initialSid = (initial.first?["defaultProperties"] as? [String: Any])?["sid"] as? String
        let initialVisitor = initial.first?["visitor_id"] as? String
        #expect(op.mobileSession?.hasAcceptedFirstOpen == true)

        op.optOutTracking()
        op.trackingQueue.sync {}
        #expect(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
        op.optInTracking()
        op.trackingQueue.sync {}
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        #expect(items.compactMap { $0["event"] as? String } ==
            ["$mobile_app_open", "$mobile_session_start", "$opt_in"])
        let newSid = (items.first?["defaultProperties"] as? [String: Any])?["sid"] as? String
        #expect(newSid != initialSid)
        #expect(items.allSatisfy {
            ($0["defaultProperties"] as? [String: Any])?["sid"] as? String == newSid
        })
        #expect(items.allSatisfy { $0["visitor_id"] as? String == op.visitorId })
        #expect(op.visitorId != initialVisitor)
    }

    @Test @MainActor func iosManualScreenReentersAndRotatesAtExactInactivityTimeout() async throws {
        let op = OursPrivacy(token: "ios-screen-reentry-\(UUID().uuidString)",
                             trackAutomaticEvents: false)
        let clock = LockedTestMobileTime(MobileTimePoint.capture())
        op.captureMobileTime = { clock.capture() }
        op.mobileQueueNowMs = { clock.capture().epochMs }
        await op.initialize()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}

        op.trackScreen("Schedule")
        op.trackingQueue.sync {}
        clock.advance(by: 1_000)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        op.trackingQueue.sync {}
        clock.advance(by: 1_799_999)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}
        op.trackScreen("Schedule")
        op.trackingQueue.sync {}

        clock.advance(by: 1_000)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        op.trackingQueue.sync {}
        clock.advance(by: 1_800_000)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        op.trackingQueue.sync {}
        op.trackScreen("Schedule")
        op.trackingQueue.sync {}

        let items = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        #expect(items.compactMap { $0["event"] as? String } ==
            ["$mobile_screen_view", "$mobile_screen_view", "$mobile_screen_view"])
        let views = items.filter { $0["event"] as? String == "$mobile_screen_view" }
        #expect(views.count == 3)
        let first = try #require(views.first?["defaultProperties"] as? [String: Any])
        let second = try #require(views.dropFirst().first?["defaultProperties"] as? [String: Any])
        let third = try #require(views.last?["defaultProperties"] as? [String: Any])
        #expect(first["sid"] as? String == second["sid"] as? String)
        #expect(second["sid"] as? String != third["sid"] as? String)
    }

    @Test @MainActor func iosStoreKitRegistrationRequiresSeparatePurchaseOptIn() async {
        let lifecycle = OursPrivacy(token: "ios-purchase-\(UUID().uuidString)",
                                     trackAutomaticEvents: true)
        await lifecycle.initialize()
        #expect(lifecycle.automaticEvents.hasAddedPurchaseObserver == false)
        lifecycle.track(event: "$ae_iap", properties: ["$ae_iap_name": "plan"])
        lifecycle.trackingQueue.sync {}
        #expect(lifecycle.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .allSatisfy { $0["event"] as? String != "$ae_iap" })

        let purchases = OursPrivacy(token: "ios-purchase-\(UUID().uuidString)",
                                     trackAutomaticEvents: false, trackAutomaticPurchases: true)
        await purchases.initialize()
        #expect(purchases.automaticEvents.hasAddedPurchaseObserver)
        #expect(purchases.automaticEvents.hasAddedObserver == false)
        purchases.automaticEvents.emitPurchasedProduct(identifier: "plan", quantity: 1, price: "12.99")
        purchases.trackingQueue.sync {}
        let iap = purchases.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .first { $0["event"] as? String == "$ae_iap" }
        #expect((iap?["eventProperties"] as? [String: Any])?["$ae_iap_price"] as? String == "12.99")
        #expect((iap?["eventProperties"] as? [String: Any])?["$ae_iap_quantity"] as? Int == 1)
        #expect((iap?["eventProperties"] as? [String: Any])?["$ae_iap_name"] as? String == "plan")

        purchases.optOutTracking()
        purchases.trackingQueue.sync {}
        purchases.automaticEvents.delegate?.track(event: "$ae_iap",
                                                   properties: ["$ae_iap_name": "plan"],
                                                   userProperties: nil)
        purchases.trackingQueue.sync {}
        #expect(purchases.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    @Test @MainActor func iosPurchaseOptInAfterOptedOutLaunchEmitsLegacyEvent() async {
        let op = OursPrivacy(token: "ios-opt-in-\(UUID().uuidString)", trackAutomaticEvents: false)
        await op.initialize(options: OursPrivacyInitOptions(
            optedOutByDefault: true, trackAutomaticPurchases: true))
        #expect(op.hasOptedOutTracking())
        #expect(op.automaticEvents.hasAddedPurchaseObserver == false)

        op.optInTracking()
        op.trackingQueue.sync {}
        #expect(op.automaticEvents.hasAddedPurchaseObserver)
        op.automaticEvents.emitPurchasedProduct(identifier: "plan", quantity: 1, price: "12.99")
        op.trackingQueue.sync {}
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        #expect(events.contains { $0["event"] as? String == "$ae_iap" })
    }

    @Test @MainActor func iosStoreKitIgnoresRequestCompletedAfterOptOutAndOptIn() async {
        let op = OursPrivacy(token: "ios-purchase-generation-\(UUID().uuidString)",
                             trackAutomaticEvents: false, trackAutomaticPurchases: true)
        await op.initialize()
        let oldRequest = SKProductsRequest(productIdentifiers: ["plan"])
        op.automaticEvents.awaitingTransactionsWriteLock.sync {
            op.automaticEvents.awaitingTransactions["plan"] = 1
            op.automaticEvents.productsRequests[ObjectIdentifier(oldRequest)] = oldRequest
        }

        op.optOutTracking()
        op.trackingQueue.sync {}
        op.optInTracking()
        op.trackingQueue.sync {}

        let newRequest = SKProductsRequest(productIdentifiers: ["plan"])
        op.automaticEvents.awaitingTransactionsWriteLock.sync {
            op.automaticEvents.awaitingTransactions["plan"] = 2
            op.automaticEvents.productsRequests[ObjectIdentifier(newRequest)] = newRequest
        }
        op.automaticEvents.completeProductsRequest(oldRequest, products: [("plan", "12.99")])
        op.automaticEvents.awaitingTransactionsWriteLock.sync {}
        op.trackingQueue.sync {}

        let afterOld = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        #expect(afterOld.allSatisfy { $0["event"] as? String != "$ae_iap" })

        op.automaticEvents.completeProductsRequest(newRequest, products: [("plan", "3.99")])
        op.automaticEvents.awaitingTransactionsWriteLock.sync {}
        op.trackingQueue.sync {}

        let purchases = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .filter { $0["event"] as? String == "$ae_iap" }
        #expect(purchases.count == 1)
        #expect((purchases.first?["eventProperties"] as? [String: Any])?["$ae_iap_name"] as? String == "plan")
        #expect((purchases.first?["eventProperties"] as? [String: Any])?["$ae_iap_price"] as? String == "3.99")
        #expect((purchases.first?["eventProperties"] as? [String: Any])?["$ae_iap_quantity"] as? Int == 2)
    }

    @Test @MainActor func foregroundTimerEmitsRepeatedEngagementWithoutBackground() async {
        let op = OursPrivacy(token: "ios-checkpoint-\(UUID().uuidString)", trackAutomaticEvents: true)
        let clock = LockedTestMobileTime(MobileTimePoint.capture())
        op.captureMobileTime = { clock.capture() }
        op.mobileQueueNowMs = { clock.capture().epochMs }
        op.mobileCheckpointIntervalMs = 20
        await op.initialize()
        op.mobileForeground(at: clock.capture())
        op.trackingQueue.sync {}
        clock.advance(by: 10_000)
        for _ in 0 ..< 50 {
            let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            if events.contains(where: { $0["event"] as? String == "$mobile_session_engagement" }) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        clock.advance(by: 11_000)
        for _ in 0 ..< 50 {
            let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            if events.filter({ $0["event"] as? String == "$mobile_session_engagement" }).count >= 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let events = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let durations = events.filter { $0["event"] as? String == "$mobile_session_engagement" }
            .compactMap { ($0["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int64 }
        #expect(durations == [10_000, 11_000])
        #expect(events.filter { $0["event"] as? String == "$mobile_app_open" }.count == 1)
        op.optOutTracking()
        op.trackingQueue.sync {}
    }

    @Test @MainActor func backgroundInitializationPreservesFirstEventMetadataAndOrder() async {
        let constructed = DispatchSemaphore(value: 0)
        let processed = DispatchSemaphore(value: 0)
        let events = AsyncStream<[(String, Set<String>)]> { continuation in
            Task.detached {
                let op = OursPrivacy(token: "ios-background-\(UUID().uuidString)", trackAutomaticEvents: false)
                constructed.signal()
                await op.initialize()
                op.track(event: "First event")
                op.identify()
                op.trackingQueue.async {
                    let queued = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
                    continuation.yield(queued.map { event in
                        let defaults = event["defaultProperties"] as? [String: Any] ?? [:]
                        return (event["event"] as? String ?? "", Set(defaults.keys))
                    })
                    continuation.finish()
                    processed.signal()
                }
            }
        }

        expectDeferredProcessing(constructed: constructed, processed: processed)
        for await snapshot in events {
            #expect(snapshot.map { $0.0 } == ["First event", "$identify"])
            let required: Set<String> = ["device_vendor", "device_model", "device_type", "os_name",
                                         "os_version", "screen_width", "screen_height", "version"]
            for (_, keys) in snapshot {
                #expect(required.isSubset(of: keys))
            }
        }
    }

    @MainActor private func expectDeferredProcessing(constructed: DispatchSemaphore, processed: DispatchSemaphore) {
        // Construction must return while main is busy, but event processing must wait
        // for main to capture UIKit metadata even if another instance warmed the cache.
        #expect(constructed.wait(timeout: .now() + .seconds(2)) == .success)
        #expect(processed.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
    }

    @Test func optedOutByDefaultRespectsPersistedOptIn() async throws {
        let op = OursPrivacy(token: "ios-test-\(UUID().uuidString)", trackAutomaticEvents: false)
        op.optInTracking()
        op.trackingQueue.sync {}
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        #expect(op.hasOptedOutTracking() == false)
    }

}
