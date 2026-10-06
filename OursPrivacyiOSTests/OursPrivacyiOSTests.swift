//
//  OursPrivacyiOSTests.swift
//  OursPrivacyiOSTests
//
//  Created by Zeytech on 4/11/25.
//  Copyright © 2025 Ours Wellness Inc. All rights reserved.
//

import Foundation
import Testing
@testable import OursPrivacyKit

struct OursPrivacyiOSTests {

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
        #expect(openDefaults?["mobile_platform"] as? String == "ios")
        #expect(openDefaults?["os_name"] as? String == "iOS")
        #expect(openDefaults?["utm_source"] == nil)
        #expect((mobile.first?["eventProperties"] as? [String: Any])?["caller_field"] == nil)
        #expect(bookedDefaults?["utm_source"] as? String == "campaign")
        #expect((booked?["eventProperties"] as? [String: Any])?["caller_field"] as? String == "private")
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
